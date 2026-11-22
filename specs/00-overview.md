# InSwapper iOS: overview

Local, fully on-device face-swap video player for iPhone 14 Pro (A16, 6 GB). Personal use only.

## Decisions (locked 2026-11-23)
- Runtime: Core ML (FP16, Neural Engine), converted from `inswapper_128.onnx` + insightface `buffalo_l` (SCRFD detector, ArcFace w600k_r50 recognizer).
- Priority: play a video file, seek anywhere, frames are swapped live during playback. Live camera is NOT needed.
- Also: photo swap, and offline export as fallback.
- Build: GitHub Actions on a macOS runner. **Public** repo (free macOS minutes). No local Xcode needed.
- Install: unsigned `.ipa` -> SideStore / LiveContainer re-signs. (Check Core ML + Photos entitlements work under LiveContainer in Phase 0.)
- Weights are NOT in the repo (550 MB, over the 100 MB limit, non-commercial licence). Because the repo is public, conversion runs LOCALLY ONLY, never in CI (CI artifacts of a public repo are downloadable by others and would republish the weights).
- Model delivery: on the Mac, zip the converted `.mlpackage` files + `emap.bin` into one `models.zip`; send to the phone via AirDrop or iCloud Drive into the Files app. `.mlpackage` is a folder bundle and the Files picker handles those poorly, hence the zip. The app imports the zip, unzips it (ZIPFoundation via SPM, since iOS has no public unzip API), and compiles with `MLModel.compileModel(at:)`, caching in Application Support.
- `emap` decision: extract `emap` (512x512) to a file, ship it in the zip, and apply it in Swift once per source face: latent = L2norm(L2norm(arcface_embedding) @ emap). It is NOT baked into the Core ML model.
- Min iOS 17, SwiftUI, Swift.

## Working rule (user, 2026-11-23)
After EVERY step (each task in a phase, and each phase), consult the advisor model (`advisor` tool) to check the work before moving on. Record the advisor's verdict in `PROGRESS.md`'s log. Make the work durable (written/committed) before calling it.

## Architecture (target)
```
AVPlayer -> AVPlayerItemVideoOutput -> CADisplayLink pull
  -> [detect (SCRFD, every N frames, tracked between)]
  -> [align 5-pt similarity -> 128x128]
  -> [inswapper (Core ML) with cached source embedding]
  -> [Metal paste-back: inverse warp + feathered mask + colour match]
  -> MTKView
Look-ahead: background queue swaps frames ahead of playhead into a ring cache.
Seek: flush tracker + cache, fresh detect at new position.
```
Source face: ArcFace embedding computed once per source photo, multiplied by `emap` (baked in at conversion), cached.

## Performance: MEASURED on iPhone 14 Pro, iOS 27.0.1, via patched LiveContainer (2026-11-23). The estimates below are SUPERSEDED.
Measured: swapper 150 ms (ANE), detector 5 ms, embedder 4 ms, sustained ~6.6 fps with detect+swap every frame, thermal nominal. Swapper = 349 GFLOPs/frame (20 big 3x3 convs, 138.6M params) -> only ~2.3 TFLOPS effective. LiveContainer works for file import + on-device compile + Core ML. Video-rate (24-30 fps) live swapping is NOT achievable with inswapper_128 on this phone. See PROGRESS.md.

### Original estimates (superseded)
- Detect 5-15 ms (skipped on tracked frames), swap 15-40 ms on ANE, paste-back 2-5 ms.
- ~10-25 fps for one face; falls with more faces. Thermal throttling after minutes.
- Biggest risk: swapper ops falling off the ANE to GPU/CPU (2-4x slower).
- Output is 128 px, so large close-up faces look soft. No enhancer in live mode.
- Memory about 280 MB for the models.

## Phases (see files in this folder)
0. `01-phase0-spike.md`: go/no-go
1. `02-phase1-photo.md`
2. `03-phase2-video-player.md`
3. `04-phase3-export.md`
4. `05-phase4-polish.md`

Progress is tracked in `PROGRESS.md`.

## Risks / open items
- coremltools has no ONNX frontend: route is onnx -> onnx2torch -> torch.jit.trace -> coremltools. Op support is unverified.
- LiveContainer may restrict some entitlements.
- GitHub repo name and visibility confirmed public; name TBD.
