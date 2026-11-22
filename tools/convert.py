"""ONNX -> torch -> Core ML (image inputs, stable I/O names), parity vs onnxruntime at every stage.
Local only (never in public CI). Usage: python convert.py {swapper|arcface|scrfd|all}

Preprocessing verified against insightface v0.7 sources:
  swapper target : RGB, x/255 (mean 0)        -> ImageType scale 1/255
  arcface        : RGB, (x-127.5)/127.5       -> ImageType scale 1/127.5, bias -1
  scrfd          : RGB, (x-127.5)/128         -> ImageType scale 1/128, bias -127.5/128
"""
import sys
from pathlib import Path
import numpy as np
import onnx
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert as onnx2torch_convert
from PIL import Image

ROOT = Path(__file__).parent / "models"
RAW = ROOT / "raw"
OUT = ROOT / "mlpackages"
OUT.mkdir(parents=True, exist_ok=True)

SCRFD_OUT = ["score_8", "score_16", "score_32", "bbox_8", "bbox_16", "bbox_32", "kps_8", "kps_16", "kps_32"]

# onnx path, onnx input names (in order), shapes, image-input spec, output names
CFG = {
    "swapper": dict(
        path=RAW / "inswapper_128.onnx",
        onnx_inputs=["target", "source"],
        shapes={"target": (1, 3, 128, 128), "source": (1, 512)},
        image={"target": dict(name="target", scale=1 / 255.0, bias=[0, 0, 0])},
        tensor={"source": "latent"},
        outputs=["swapped"],
    ),
    "arcface": dict(
        path=RAW / "buffalo_l" / "w600k_r50.onnx",
        onnx_inputs=["input.1"],
        shapes={"input.1": (1, 3, 112, 112)},
        image={"input.1": dict(name="face", scale=1 / 127.5, bias=[-1, -1, -1])},
        tensor={},
        outputs=["embedding"],
    ),
    "scrfd": dict(
        path=RAW / "buffalo_l" / "det_10g.onnx",
        onnx_inputs=["input.1"],
        shapes={"input.1": (1, 3, 640, 640)},
        image={"input.1": dict(name="image", scale=1 / 128.0, bias=[-127.5 / 128.0] * 3)},
        tensor={},
        outputs=SCRFD_OUT,
    ),
}


def fix_shapes(model, shapes):
    for inp in model.graph.input:
        if inp.name in shapes:
            for d, v in zip(inp.type.tensor_type.shape.dim, shapes[inp.name]):
                d.ClearField("dim_param")
                d.dim_value = v
    return onnx.shape_inference.infer_shapes(model)


def cmp(tag, a, b):
    a, b = np.asarray(a, np.float32), np.asarray(b, np.float32)
    diff = np.abs(a - b)
    print(f"  [{tag}] max abs diff {diff.max():.6f}  mean {diff.mean():.6f}  ref range [{b.min():.3f},{b.max():.3f}]")
    return float(diff.max())


def make_feeds(cfg, seed=0):
    """Returns (uint8 images by onnx name, float feeds for onnx/torch (already normalised))."""
    rng = np.random.default_rng(seed)
    imgs, feeds = {}, {}
    for k in cfg["onnx_inputs"]:
        shp = cfg["shapes"][k]
        if k in cfg["image"]:
            spec = cfg["image"][k]
            u8 = rng.integers(0, 256, (shp[2], shp[3], 3), dtype=np.uint8)  # HWC RGB
            imgs[k] = u8
            x = u8.astype(np.float32) * spec["scale"] + np.array(spec["bias"], np.float32)
            feeds[k] = np.ascontiguousarray(x.transpose(2, 0, 1)[None])
        else:
            v = rng.standard_normal(shp).astype(np.float32)
            v /= np.linalg.norm(v)
            feeds[k] = v
    return imgs, feeds


def convert_one(name):
    cfg = CFG[name]
    print(f"== {name}: {cfg['path'].name}")
    model = fix_shapes(onnx.load(str(cfg["path"])), cfg["shapes"])
    fixed = ROOT / f"{name}_fixed.onnx"
    onnx.save(model, str(fixed))

    imgs, feeds = make_feeds(cfg)
    sess = ort.InferenceSession(str(fixed), providers=["CPUExecutionProvider"])
    out_names = [o.name for o in sess.get_outputs()]
    ref = sess.run(out_names, feeds)

    tmodel = onnx2torch_convert(str(fixed)).eval()
    tin = [torch.from_numpy(feeds[k]) for k in cfg["onnx_inputs"]]
    with torch.no_grad():
        tout = tmodel(*tin)
    tout = list(tout) if isinstance(tout, (tuple, list)) else [tout]
    if max(cmp(f"torch {n}", t.numpy(), r) for n, t, r in zip(out_names, tout, ref)) > 1e-3:
        print("  STOP: onnx2torch deviates"); return 1

    traced = torch.jit.trace(tmodel, tin, strict=False)
    with torch.no_grad():
        t2 = traced(*tin)
    t2 = list(t2) if isinstance(t2, (tuple, list)) else [t2]
    if max(cmp(f"traced {n}", t.numpy(), r) for n, t, r in zip(out_names, t2, ref)) > 1e-3:
        print("  STOP: trace deviates"); return 1

    ml_inputs = []
    for k in cfg["onnx_inputs"]:
        if k in cfg["image"]:
            s = cfg["image"][k]
            ml_inputs.append(ct.ImageType(name=s["name"], shape=cfg["shapes"][k], scale=s["scale"],
                                          bias=s["bias"], color_layout=ct.colorlayout.RGB))
        else:
            ml_inputs.append(ct.TensorType(name=cfg["tensor"][k], shape=cfg["shapes"][k], dtype=np.float32))
    ml = ct.convert(
        traced, inputs=ml_inputs,
        outputs=[ct.TensorType(name=n, dtype=np.float16) for n in cfg["outputs"]],
        convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    pkg = OUT / f"{name}.mlpackage"
    ml.save(str(pkg))
    print("  saved", pkg)

    pred_in = {}
    for k in cfg["onnx_inputs"]:
        if k in cfg["image"]:
            pred_in[cfg["image"][k]["name"]] = Image.fromarray(imgs[k], "RGB")
        else:
            pred_in[cfg["tensor"][k]] = feeds[k]
    pred = ml.predict(pred_in)
    worst = 0.0
    for n, r in zip(cfg["outputs"], ref):
        worst = max(worst, cmp(f"coreml {n}", pred[n], r))
    if name == "arcface":
        a, b = ref[0][0], np.asarray(pred["embedding"], np.float32)[0]
        print(f"  arcface cosine vs ONNX: {float(a @ b / np.linalg.norm(a) / np.linalg.norm(b)):.5f}")
    return 0


if __name__ == "__main__":
    names = list(CFG) if sys.argv[1] == "all" else [sys.argv[1]]
    sys.exit(max(convert_one(n) for n in names))
