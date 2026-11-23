# Weight-compression variants of the swapper for the perf research (local only; weights never leave this Mac).
# usage: compress_exp.py <variant: pal8|pal6|pal4|int8>
import sys, coremltools as ct, coremltools.optimize.coreml as cto
v = sys.argv[1]
m = ct.models.MLModel("tools/models/mlpackages/swapper.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)
if v.startswith("pal"):
    cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=int(v[3:])))
    out = cto.palettize_weights(m, cfg)
else:
    cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", weight_threshold=512))
    out = cto.linear_quantize_weights(m, cfg)
out.save(f"tools/models/exp/swapper_{v}.mlpackage")
print("saved", v)
