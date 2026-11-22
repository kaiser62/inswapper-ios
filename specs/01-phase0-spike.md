# Phase 0: Go/no-go spike

**Goal:** prove the models convert and run fast enough on an iPhone 14 Pro, and that the CI -> SideStore pipeline works. Nothing else.

## Tasks
1. Create public GitHub repo (name TBD, confirm with user). Requires `gh auth status` OK.
2. Local Python env (Python 3.11+, venv): `coremltools`, `torch`, `onnx`, `onnx2torch`, `onnxruntime`, `insightface` (for reference only).
3. Obtain weights locally (confirm source with user first; non-commercial): `inswapper_128.onnx`, `buffalo_l` det_10g + w600k_r50.
4. Convert to `.mlpackage` (FP16, `compute_units=ALL`), LOCALLY ONLY (never in public CI):
   - swapper: inputs target face 1x3x128x128 and latent 1x512. `emap` is NOT baked in: extract it to `emap.bin` (512x512 float32), applied in Swift: latent = L2norm(L2norm(arcface_emb) @ emap).
   - detector (SCRFD): Core ML needs a fixed input size (640x640); rewrite anchor decoding + NMS in Swift. Fallback: Apple Vision face landmarks (derive the 5 points; verify alignment quality holds).
   - recognizer (ArcFace 112x112)
   Check each against insightface `model_zoo/inswapper.py`, `arcface_onnx.py`, `scrfd.py`:
   - Normalisation: swapper target RGB x/255, output RGB 0-1; ArcFace (x-127.5)/127.5 on 112px aligned face; SCRFD (x-127.5)/128.
   - Alignment template (verified in insightface `face_align.estimate_norm`): for a 128px crop, ratio = 1.0 and x is shifted +8 px, i.e. the 112 ArcFace template, NOT enlarged: dst = [[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],[41.5493,92.3655],[70.7299,92.2041]] with x += 8. ArcFace itself uses the unshifted 112 template. Similarity transform (not full affine).
   - Verified swapper I/O (insightface `inswapper.py`): `emap` = `graph.initializer[-1]`; input 0 = target blob (RGB, x/255, mean 0), input 1 = latent (1x512); output RGB 0-1, 1x3x128x128 (multiply by 255, clip). Paste-back mask logic (erode/blur/diff mask) is in `get()`: copy it in Phase 1. ArcFace: RGB, (x-127.5)/127.5.
   - Package: zip all `.mlpackage` + `emap.bin` into `models.zip` for delivery (AirDrop / iCloud Drive -> Files).
5. Verify each against onnxruntime on test images (max abs diff within FP16 tolerance, visual check).
6. Minimal SwiftUI benchmark app: import `models.zip` via Files (ZIPFoundation via SPM), compile on device, run each model N=100 times on a fixed input, report mean/p95 ms. Compute units: Core ML doesn't expose this directly, so use `MLComputePlan` (iOS 17.4+, per-op device) and also time each model under `.cpuOnly`, `.cpuAndGPU`, `.cpuAndNeuralEngine`. Also read `ProcessInfo.thermalState`.
7. GitHub Actions workflow (`macos-14` or newer): `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`, zip `Payload/*.app` to `.ipa`, upload artifact.
8. User installs via SideStore, imports models, runs benchmark, reports numbers.

## Done when
- Models converted and verified vs ONNX.
- `.ipa` builds in CI and installs via SideStore.
- Benchmark numbers recorded in `PROGRESS.md`.

## Go/no-go gate
- GO: swapper <= ~40 ms and mostly on ANE, plus detector fast enough to run every few frames. This allows ~10+ fps live, or smooth playback with look-ahead.
- NO-GO / change approach: swapper > ~100 ms or on CPU. Options: partial ANE-friendly rewrite, lower the effective fps, export-only mode.

## Risks
- Conversion fails on unsupported ops (instance norm / style modulation).
- LiveContainer blocks file import or Core ML compile.
