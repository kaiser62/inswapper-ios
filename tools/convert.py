"""ONNX -> torch -> Core ML, checking parity vs onnxruntime after every stage.
Local only. Usage: python convert.py {swapper|arcface|scrfd}
"""
import sys
from pathlib import Path
import numpy as np
import onnx
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert as onnx2torch_convert

ROOT = Path(__file__).parent / "models"
RAW = ROOT / "raw"
OUT = ROOT / "mlpackages"
OUT.mkdir(parents=True, exist_ok=True)

CFG = {
    # name: (onnx path, {input name: shape}, output dir name)
    "swapper": (RAW / "inswapper_128.onnx", {"target": (1, 3, 128, 128), "source": (1, 512)}),
    "arcface": (RAW / "buffalo_l" / "w600k_r50.onnx", {"input.1": (1, 3, 112, 112)}),
    "scrfd": (RAW / "buffalo_l" / "det_10g.onnx", {"input.1": (1, 3, 640, 640)}),
}


def rand_inputs(name, shapes, seed=0):
    rng = np.random.default_rng(seed)
    d = {}
    for k, s in shapes.items():
        if name == "swapper" and k == "source":
            v = rng.standard_normal(s).astype(np.float32)
            v /= np.linalg.norm(v)
        elif name == "swapper":
            v = rng.random(s).astype(np.float32)  # RGB 0-1 after /255
        else:
            v = rng.uniform(-1, 1, s).astype(np.float32)
        d[k] = v
    return d


def fix_shapes(model, shapes):
    for inp in model.graph.input:
        if inp.name in shapes:
            dims = inp.type.tensor_type.shape.dim
            for d, v in zip(dims, shapes[inp.name]):
                d.ClearField("dim_param")
                d.dim_value = v
    return onnx.shape_inference.infer_shapes(model)


def cmp(tag, a, b):
    a, b = np.asarray(a, np.float32), np.asarray(b, np.float32)
    diff = np.abs(a - b)
    print(f"  [{tag}] max abs diff {diff.max():.6f}  mean {diff.mean():.6f}  ref range [{b.min():.3f},{b.max():.3f}]")
    return float(diff.max())


def main(name):
    path, shapes = CFG[name]
    print(f"== {name}: {path.name}")
    model = fix_shapes(onnx.load(str(path)), shapes)
    fixed = ROOT / f"{name}_fixed.onnx"
    onnx.save(model, str(fixed))

    # stage 0: onnxruntime reference
    sess = ort.InferenceSession(str(fixed), providers=["CPUExecutionProvider"])
    feeds = rand_inputs(name, shapes)
    out_names = [o.name for o in sess.get_outputs()]
    ref = sess.run(out_names, feeds)
    print("  ort outputs:", [(n, r.shape) for n, r in zip(out_names, ref)])

    # stage 1: onnx -> torch
    tmodel = onnx2torch_convert(str(fixed)).eval()
    tin = [torch.from_numpy(feeds[k]) for k in shapes]
    with torch.no_grad():
        tout = tmodel(*tin)
    tout = list(tout) if isinstance(tout, (tuple, list)) else [tout]
    worst = max(cmp(f"torch {n}", t.numpy(), r) for n, t, r in zip(out_names, tout, ref))
    if worst > 1e-3:
        print("  STOP: onnx2torch output deviates from onnxruntime"); return 1

    # stage 2: trace
    traced = torch.jit.trace(tmodel, tin, strict=False)
    with torch.no_grad():
        t2 = traced(*tin)
    t2 = list(t2) if isinstance(t2, (tuple, list)) else [t2]
    worst = max(cmp(f"traced {n}", t.numpy(), r) for n, t, r in zip(out_names, t2, ref))
    if worst > 1e-3:
        print("  STOP: traced model deviates"); return 1

    # stage 3: Core ML
    ml_inputs = [ct.TensorType(name=k.replace(".", "_"), shape=shapes[k], dtype=np.float32) for k in shapes]
    ml = ct.convert(
        traced,
        inputs=ml_inputs,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    pkg = OUT / f"{name}.mlpackage"
    ml.save(str(pkg))
    print("  saved", pkg)

    # stage 4: Core ML prediction on this Mac vs onnxruntime
    pred = ml.predict({k.replace(".", "_"): v for k, v in feeds.items()})
    spec_out = list(ml.get_spec().description.output)
    # outputs may be renamed; compare in declared order
    for o, r in zip(spec_out, ref):
        cmp(f"coreml {o.name}", pred[o.name], r)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
