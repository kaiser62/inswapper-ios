"""Inspect the ONNX models and extract emap.bin (local only; outputs are gitignored)."""
import sys
from pathlib import Path
import numpy as np
import onnx
from onnx import numpy_helper

RAW = Path(__file__).parent / "models" / "raw"
OUT = Path(__file__).parent / "models"


def io_summary(path):
    m = onnx.load(str(path))
    g = m.graph
    inits = {i.name for i in g.initializer}
    ins = [(i.name, [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim])
           for i in g.input if i.name not in inits]
    outs = [(o.name, [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]) for o in g.output]
    ops = {}
    for n in g.node:
        ops[n.op_type] = ops.get(n.op_type, 0) + 1
    return m, ins, outs, ops


for p in [RAW / "inswapper_128.onnx", RAW / "buffalo_l" / "det_10g.onnx", RAW / "buffalo_l" / "w600k_r50.onnx"]:
    m, ins, outs, ops = io_summary(p)
    print(f"\n== {p.name}  opset={[o.version for o in m.opset_import]}")
    print(" inputs :", ins)
    print(" outputs:", outs)
    print(" ops    :", dict(sorted(ops.items(), key=lambda kv: -kv[1])))

# emap
m = onnx.load(str(RAW / "inswapper_128.onnx"))
g = m.graph
last = g.initializer[-1]
emap = numpy_helper.to_array(last)
consumers = [n.name or n.op_type for n in g.node if last.name in n.input]
print("\nemap initializer:", last.name, emap.shape, emap.dtype,
      "consumed by graph nodes:", consumers)
assert emap.shape == (512, 512), emap.shape
OUT.mkdir(exist_ok=True)
emap.astype("<f4").tofile(OUT / "emap.bin")
print("wrote", OUT / "emap.bin", (OUT / "emap.bin").stat().st_size, "bytes (expect", 512 * 512 * 4, ")")
