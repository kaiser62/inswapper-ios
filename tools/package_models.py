"""Build models.zip (+ manifest.json) for import in the iOS app via Files. Local only; output is gitignored."""
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).parent / "models"
PK = ROOT / "mlpackages"
FORMAT_VERSION = 1

manifest = {
    "format_version": FORMAT_VERSION,
    "note": "Personal use only: inswapper/insightface weights are non-commercial research licence.",
    "models": {
        "scrfd": {
            "file": "scrfd.mlpackage",
            "input": {"name": "image", "type": "image", "size": [640, 640], "color": "RGB",
                      "preprocess": "(x-127.5)/128 applied inside the model",
                      "letterbox": "resize keeping aspect, paste top-left on 640x640 canvas, divide boxes/kps by det_scale"},
            "outputs": ["score_8", "score_16", "score_32", "bbox_8", "bbox_16", "bbox_32", "kps_8", "kps_16", "kps_32"],
            "decode": {"strides": [8, 16, 32], "anchors_per_cell": 2,
                       "anchor_centers": "grid (x,y)*stride, each centre repeated consecutively x2",
                       "bbox": "distance2bbox(center, pred*stride)", "kps": "center + pred*stride (5 points)",
                       "det_thresh": 0.5, "nms_thresh": 0.4},
        },
        "arcface": {
            "file": "arcface.mlpackage",
            "input": {"name": "face", "type": "image", "size": [112, 112], "color": "RGB",
                      "preprocess": "(x-127.5)/127.5 applied inside the model",
                      "align": "similarity transform of 5 kps to ArcFace 112 template (no x shift)"},
            "outputs": ["embedding"], "output_shape": [1, 512], "post": "L2-normalise",
        },
        "swapper": {
            "file": "swapper.mlpackage",
            "inputs": {"target": {"type": "image", "size": [128, 128], "color": "RGB",
                                  "preprocess": "x/255 applied inside the model",
                                  "align": "5 kps to ArcFace 112 template with x += 8 (insightface estimate_norm for size 128)"},
                       "latent": {"type": "multiarray", "shape": [1, 512], "dtype": "float32",
                                  "compute": "L2norm(L2norm(arcface_embedding) @ emap)"}},
            "outputs": ["swapped"], "output_shape": [1, 3, 128, 128], "output_range": "RGB 0..1 (x255, clip)",
        },
    },
    "emap": {"file": "emap.bin", "dtype": "float32", "endian": "little", "shape": [512, 512], "layout": "row-major",
             "usage": "latent_row(1x512) @ emap"},
}

stage = ROOT / "stage"
if stage.exists():
    shutil.rmtree(stage)
stage.mkdir()
for n in ["scrfd", "arcface", "swapper"]:
    shutil.copytree(PK / f"{n}.mlpackage", stage / f"{n}.mlpackage")
shutil.copy(ROOT / "emap.bin", stage / "emap.bin")
(stage / "manifest.json").write_text(json.dumps(manifest, indent=2))

zp = ROOT / "models.zip"
if zp.exists():
    zp.unlink()
with zipfile.ZipFile(zp, "w", zipfile.ZIP_STORED) as z:  # stored: weights barely compress
    for f in sorted(stage.rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(stage))
print(zp, round(zp.stat().st_size / 1e6, 1), "MB")
