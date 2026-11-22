# Phase 1: Photo swap

**Goal:** full pipeline on still images, which forms the core every later phase reuses.

## Scope
- First-launch model import (Files picker) with validation, compile, and caching in Application Support.
- Pick source face photo and target photo (PhotosPicker).
- Detect faces, let user pick which target face(s) to swap, compute and cache source embedding.
- Pipeline module (reused by video): `FaceDetector`, `FaceAligner` (5-pt similarity transform to 128 px), `Swapper`, `PasteBack` (inverse warp, feathered mask, colour matching).
- Save result to Photos.

## Spec details
- Pipeline code must be frame-in / frame-out on `CVPixelBuffer` so video can reuse it.
- Phase 1 paste-back is a CPU compositor with an analytic mask (verified 57 dB vs insightface's erode+blur mask; ~7 ms for a 866x1381 photo on a Mac). Metal comes in Phase 2 when per-frame cost matters. No colour matching: insightface's inswapper does none either.
- Core lives in `app/Core` (platform-neutral Swift, no UIKit) so it builds and runs on a Mac: `tools/swiftcheck/run.sh` compares it to the Python golden data (local, face data). Synthetic unit tests (no face data) in `tools/ci-tests`, run in CI with plain `swiftc` on the macOS runner (no simulator).
- Decode photos with ImageIO + orientation transform (`PixelBuf.load(data:)`), never `UIImage.cgImage`.
- Same app/bundle ID as the benchmark so imported models carry over. Share sheet is the main save path; Save to Photos is best-effort under LiveContainer.
- The result screen shows per-stage timings (letterbox, scrfd, decode+nms, warp, arcface, swapper, composite) to measure the Swift CPU cost on device.

## Done when
- A swap on a real photo looks correct on device, within about 1 s per image.
- Multiple faces handled (select which to swap).
- Quality compared to the Python reference output on the same input.
