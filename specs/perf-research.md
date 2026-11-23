# Performance research: cutting time per step (2026-11-23)

Scope set with the advisor: measure first, then research only what the numbers justify. Weights and face data stay local.
Harnesses (Mac, M4): `tools/stagecheck` (per-stage table), `tools/perfcheck` (swapper variant x compute unit, parity vs shipped), `tools/compress_exp.py` (weight-compression variants, output in gitignored `tools/models/exp/`), `tools/strengthcheck` (identity cosine + PNG dump via `OUT=`).

## 1. Where the time goes (Mac M4, 1280x720 and 720x1280 clips, ms per frame)
| stage | ms | share |
|---|---|---|
| swapper (ANE) | 120-123 | ~93% |
| decode (read) | 2-6 | 2-4% |
| SCRFD (ANE) + letterbox + nms + readback | ~8 | 6% |
| warp | 0.5-1 | <1% |
| detect+swap total | 127-132 | |
Device (iPhone 14 Pro, spec 0.x): swapper 150, SCRFD 4-6. So **every non-swapper stage together is ~10 ms; only the swapper and heat matter.** Overlapping decode/detect with the swap (pipelining) is worth at most ~8%, low priority.

## 2. Is the swapper on the ANE? Yes (device compute plan: 239/241 ops on ANE), yet it takes 150 ms.
Compute-unit sweep, Mac M4, same crop: cpu+ANE 119.6 ms, cpu+GPU 82.9 ms, CPU only 121.6 ms. Mac numbers do not transfer to the A16 (its GPU is far smaller than the M4's), so the **GPU option must be measured on the phone** (experiment E1). The ANE time looking like the CPU time suggests the ANE is bound by weight traffic, not arithmetic: the model is 264 MB of FP16 weights for a 128x128 image.

## 3. Lever 1: weight compression (measured on Mac, ANE)
Apple's coremltools docs say 1-8 bit palettization usually helps most on the Neural Engine (fewer bytes moved, decompressed just in time on ANE since iOS 17), and that int8 activation paths need A17 Pro / M4 (so not the A16). Measured on the swapper:

| variant | size | ANE ms | diff vs shipped (mean / max, of 255) | verdict |
|---|---|---|---|---|
| shipped FP16 | 264 MB | 119.6 | - | baseline |
| **palettize 8-bit** | 132 MB | **47.9 (2.5x)** | 0.78 / 9.4 | invisible side by side |
| int8 weight-only | 132 MB | 48.0 | 0.87 / 11.9 | same as pal8; GPU path crashes (ANE/CPU only) |
| palettize 6-bit | 99 MB | 38.1 | 4.4 / 41 | visible risk, needs eyes |
| palettize 4-bit | 66 MB | 28.8 | 89 / 222 | broken |
For scale, the shipped model itself differs from its own CPU+GPU output by 0.43 mean / 2.0 max, so 0.8 is close to noise.
End to end (strengthcheck, 3 frames, same source): ArcFace cosine to source 0.920/0.923 shipped vs 0.922/0.925 with pal8 (no identity loss); side-by-side composited frame (`build/vis_cmp.png`, local) is visually indistinguishable. A pal8 swap is 49 ms vs 120 ms; strength 200 costs ~98 ms vs ~240 ms. Cache/export render time falls the same ratio.
**Caveat:** this is the M4 ANE. Apple's own A16 table (MobileNetV2, tiny weights) shows almost no gain, but that model is not weight-bound. Whether the A16 gains 2.5x is the most important open question (experiment E2).

## 4. Other levers, ranked
| lever | expected gain | cost / risk |
|---|---|---|
| pal8 swapper (above) | up to ~2.5x if A16 behaves like the M4; less heat per swap is plausible (fewer bytes moved), unmeasured | low: local conversion done, ship as optional model, A/B on device |
| Measure GPU (cpu+GPU) on the phone | M4 shows 1.45x; A16 unknown | trivial (compute-unit switch in Bench). Note GPU use also contends with the Metal compositor |
| Thermal duty cycle | sustained 2.4/s vs 6.4/s = 2.6x lost, as big as any model gain | measure 5 min per compute unit (user's pending run); try steady rate vs run-hot-then-sleep. Literature: ANE sustains ~67% of burst on a 10 min LLM run vs 38% on the GPU (blog, iPhone 17 Pro), and Apple's power manager, not the ANE, throttles, so lower bytes/swap should help |
| Fewer swaps (patch reuse between keyframes) | N=4 needs only ~6 swaps/s for 24 fps | already tried as Mode C and dropped for temporal artefacts; keep dropped unless pal8 fails |
| Replacement/distilled swapper | none found smaller | HyperSwap_1a_256 is 403 MB (research-use licence), ReSwapper 256 is 554 MB and AGPL-3.0: both bigger than ours, so no speed gain. A distilled student means training our own model from inswapper outputs (weights licence is non-commercial anyway; personal use only here): large project, only if compression is exhausted |
| Decode/detect pipelining, fewer buffer copies | <=8% | skip |
| Background render slowdown | Apple DTS: background ML ran 4-5x slower (GPU suspected) | irrelevant, we only render in the foreground |

## 5. Proposed experiments (need the user's go; E2 and E3 need the phone)
- E1: Bench tab compute-unit sweep of the swapper (cpuAndNE, cpuAndGPU, all) on the phone, 30 swaps each.
- E2: ship `swapper_pal8` as an optional second model (zip next to models.zip; Bench shows both side by side: ms, and sustained 5 min swaps/s + thermal state). Decision rule: adopt as default if device swap <= ~80 ms and the eyeball compare is clean.
- E3: if pal8 works, also try 6-bit with a per-op sensitivity pass (keep first/last layers 8-bit) and `ct.optimize.torch` calibrated palettization to claw back the 4.4 mean error; target ~40 ms.
- E4: thermal duty-cycle test with the best model (steady 5/s cap vs unconstrained).
- If E2 fails on A16: fall back to the GPU path (E1) or the distillation project.

## Sources
coremltools optimisation docs (palettization perf, quantization perf, Accuracy and Performance: apple.github.io/coremltools); arXiv 2606.22283 (ANE architecture, throttling by system power manager; lower confidence); dev.to "GPU wins the sprint, ANE wins the marathon" (blog benchmark); Apple Developer Forums threads 817111, 807957; FaceFusion model repo listing (hyperswap size/licence, sources disagree); ReSwapper GitHub/HF (AGPL-3.0, 554 MB).
