"""Export golden.npz (Core ML run) to simple files for the Swift harness. Local only (face data)."""
import json, sys
from pathlib import Path
import numpy as np
T = Path(__file__).parent / "models" / "test"
g = np.load(T / "golden.npz")
out = T / "golden"; out.mkdir(exist_ok=True)
j = {k: g["cml_" + k].astype(float).ravel().tolist() for k in ["skps", "tkps", "latent", "M", "emb"]}
(out / "golden.json").write_text(json.dumps(j))
g["cml_fake"].astype(np.uint8).tofile(out / "fake_bgr.bin")   # 128x128x3 BGR
g["cml_a128"].astype(np.uint8).tofile(out / "a128_bgr.bin")
print("exported", {k: len(v) for k, v in j.items()}, g["cml_fake"].shape)
