# Progress tracker

Last updated: 2026-11-23. Status: planning complete, no code written.

| Phase | Spec | Status | Notes |
|---|---|---|---|
| 0 Spike (convert + benchmark + CI) | 01-phase0-spike.md | NOT STARTED | Waiting for user "go" |
| 1 Photo swap | 02-phase1-photo.md | not started | |
| 2 Video player + seeking | 03-phase2-video-player.md | not started | main feature |
| 3 Export | 04-phase3-export.md | not started | |
| 4 Polish | 05-phase4-polish.md | not started | |

## Working rule
After every step, consult the advisor to check the work; log its verdict below.

## Note
`ios-dev/` is not under git yet. When the GitHub repo exists, move/commit `specs/` into it. Until then this folder is the source of truth.

## Open items before Phase 0
- [ ] User says "go"
- [ ] GitHub repo name (public) and `gh auth status`
- [ ] Confirm where to download the weights from (non-commercial, personal use)
- [ ] Python 3.11+ available locally (system python is 3.9)

## Benchmark results (fill in after Phase 0)
| Model | Mean ms | p95 ms | Compute unit |
|---|---|---|---|
| SCRFD detector | | | |
| ArcFace | | | |
| inswapper | | | |

## Log
- 2026-11-23: Plan agreed. Decisions: Core ML, video playback with live swap and seek (no live camera), GitHub Actions build on a public repo, SideStore install, models imported via the Files app.
- 2026-11-23: Advisor review of the specs. Verdict: solid base, fixed 6 issues: look-ahead needs its own AVAssetReader (not AVPlayerItemVideoOutput); models delivered as models.zip (.mlpackage is a folder); conversion local-only (public repo CI would republish weights); Phase 0 now lists normalisation, alignment template, emap handling, SCRFD fixed-size + Vision fallback; benchmark uses MLComputePlan / per-compute-unit timing; memory notes saved. Phase 0 NOT started, awaiting user "go".
- 2026-11-23: User said "go" -> Phase 0 started. Step 0.1 env: `gh` logged in as kaiser62; python3.11 venv at `ios-dev/tools/.venv` with coremltools 9.0, torch 2.7.0 (pinned; coremltools untested above 2.7), onnx, onnx2torch, onnxruntime. No weights on disk yet; needs user OK to download (not done). Repo not created yet (name TBD).
- 2026-11-23: Advisor on 0.1: env OK pending torchvision check. Fixed: onnx2torch failed to import (torchvision::nms) -> pinned torchvision 0.22.0; `pip check` clean; `tools/requirements.txt` frozen; `.gitignore` added (.venv, tools/models, *.onnx, *.mlpackage, models.zip, emap.bin); `tools/models/raw/` created. Weight sources found via HEAD: buffalo_l.zip (GitHub deepinsight/insightface v0.7, 288,621,354 B); inswapper_128.onnx (HF ezioruan mirror, 554,253,681 B, sha256 e4a3f08c...16af). Awaiting user approval for downloads + repo name. Advisor also says: read insightface inswapper.py to confirm where emap is read from, and check emap is 512x512 before writing emap.bin.
- 2026-11-23: Step 0.2 done: user approved downloads + repo. Weights in `tools/models/raw/` (gitignored): inswapper_128.onnx sha256 matches the mirror's published hash e4a3f08c...16af (confirms an intact download, not provenance); buffalo_l unzipped (det_10g.onnx, w600k_r50.onnx + others). Public repo created: https://github.com/kaiser62/inswapper-ios (branch main, specs + .gitignore + tools/requirements.txt pushed, no weights). Next: 0.3 inspect insightface inswapper.py for emap, extract emap.bin (verify 512x512), then convert models.
- 2026-11-23: Advisor on 0.2: fixed. Commit author is the noreply address (no personal email exposed); repo-local git identity set to 32761972+kaiser62@users.noreply.github.com. Alignment template CORRECTED in spec 01: 128px template = 112 ArcFace template with x += 8 (not scaled), verified in insightface face_align.py. emap = initializer[-1] confirmed in inswapper.py. Step 0.3 next: extract emap (check 512x512 float32, not consumed by graph nodes), then convert stage by stage, checking vs onnxruntime after each stage. Test face image: ask user, don't search their photos.
- 2026-11-23: Step 0.3 conversion done (local). `tools/inspect_onnx.py` + `tools/convert.py` (staged: ort ref -> onnx2torch -> jit.trace -> Core ML mlprogram FP16 iOS17, parity at each stage). emap.bin extracted (512x512 f32, 1,048,576 B, unconsumed by graph). Results on RANDOM inputs only (real face test still pending, needs a test image from the user): swapper torch/trace diff 4.6e-5, Core ML FP16 max 0.021 mean 0.0029; arcface torch 8e-6, Core ML cosine vs ONNX 0.992-0.997 (20 random inputs); scrfd torch ~5e-6, Core ML max 0.09 mean ~0.01 (9 outputs, fixed 640x640). Sizes: swapper 264M, arcface 83M, scrfd 8.2M. SCRFD converted fine, so the Vision fallback is not needed so far. Open: real-image parity, models.zip packaging, benchmark app, CI.
- 2026-11-23: Advisor on 0.3: conversion OK on random inputs; open items were SCRFD preprocessing, ImageType + renamed I/O, Mac compute-plan check, real-image parity, manifest. Done since: (1) SCRFD/ArcFace/swapper/face_align verified against insightface v0.7 sources (only tags are v0.7, model-zoo): SCRFD RGB (x-127.5)/128, letterbox top-left on 640 canvas, strides 8/16/32 x2 anchors (centres repeated consecutively), bbox/kps = distance*stride, det_thresh 0.5, NMS 0.4, ONNX output order scores,bbox,kps matches. (2) Re-converted with ImageType inputs (swapper scale 1/255; arcface 1/127.5 bias -1; scrfd 1/128 bias -127.5/128), FP16 outputs, stable names: swapper(target,latent->swapped), arcface(face->embedding, cosine 0.9977 vs ONNX), scrfd(image->score_/bbox_/kps_ 8/16/32). Parity still random-input only. (3) MLComputePlan on this Mac (CPU_AND_NE): swapper 240/240 ops prefer ANE, arcface 133/133, scrfd 134 ANE + 4 CPU (output transpose/reshape). It is a placement PLAN, not speed: device benchmark still decides. (5) `tools/package_models.py` builds `models.zip` (373.6 MB, stored) with manifest.json (format_version 1) + emap.bin; gitignored. STILL OPEN: (4) real-image parity via `tools/reference_pipeline.py`, awaiting one source-face photo + one target photo/clip from the user into `tools/models/test/` (gitignored; no face images in the public repo). Then benchmark app + CI.
- 2026-11-23: Advisor (Opus 5.5) on 0.3 follow-ups: items 1,2,3,5 pass. Correction accepted: real-image parity does NOT block the benchmark (timing is image-independent). Step 0.4 done: benchmark app `app/` (XcodeGen project.yml, ZIPFoundation 0.9.20 pinned, iOS 17, Swift 5 mode) + `.github/workflows/build-ios.yml` (macos-15, Xcode 26.3 selected explicitly, unsigned archive, IPA artifact). First CI run failed (Xcode 26 SDK picks async `prediction(from:)` -> needed `await`), second run green (run 45065662626); IPA 158 KB, local copy `ios-dev/InSwapBench.ipa` (gitignored). App: import models.zip via fileImporter (security-scoped, unzip, manifest format_version check, compileModel then move .mlmodelc out of tmp), real BGRA CVPixelBuffer inputs, load/warmup/mean/p95 under cpuAndNeuralEngine/cpuAndGPU/all/cpuOnly, on-device MLComputePlan (iOS 17.4+), 60 s sustained scrfd+swapper loop with fps + thermalState, Copy results button. `tools/reference_pipeline.py` written + compiles, NOT yet run (needs test images in tools/models/test/). NEXT (user): AirDrop/Files models.zip (tools/models/models.zip, 373.6 MB) + install InSwapBench.ipa via SideStore, run benchmark, paste results here. Also awaiting: iOS version, test photos.
- Note: claude-mem observer credentials were failing (needs `/login`); this folder is the source of truth for continuing.
