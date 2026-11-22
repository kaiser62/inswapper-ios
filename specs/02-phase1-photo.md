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
- Paste-back in Metal or Core Image, not CPU.
- Unit tests for alignment math (CI runs `xcodebuild test` on simulator).

## Done when
- A swap on a real photo looks correct on device, within about 1 s per image.
- Multiple faces handled (select which to swap).
- Quality compared to the Python reference output on the same input.
