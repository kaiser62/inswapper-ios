# Phase 2: Video player with swapping (REWRITTEN 2026-11-23 after device benchmark)

**Why rewritten:** measured swapper = 150 ms/frame on iPhone 14 Pro (~6.5 swaps/s). Video-rate (24-30 fps) live swapping is not achievable with inswapper_128. User chose to COMBINE three modes (see below).

**Goal:** open a video, play and seek anywhere, and get swapped faces as fast as the phone allows, with honest feedback about what is ready.

## Shared architecture
- `AVPlayer` = audio + clock master. Display from a swap cache keyed by presentation timestamp (PTS), rendered with `MTKView` / `AVSampleBufferDisplayLayer`.
- A separate `AVAssetReader` decodes frames ahead of the playhead for the swap pipeline. It cannot seek: on every seek, cancel and recreate it with `timeRange` from the new position.
- Per frame: letterbox -> SCRFD (5 ms) -> align (Umeyama, +8 template) -> swapper (150 ms) -> paste-back (Metal) -> cache. Source embedding + `emap` latent computed once per source face.
- Pipeline code is frame-in/frame-out (`CVPixelBuffer`) and shared with Phase 1 (photo) and Phase 3 (export).
- Memory: ring cache of swapped frames with a byte cap; evict behind the playhead.

## Mode A: Background render from the playhead (PRIMARY, recommended)
- Seek anywhere: swapping starts at that point and runs ahead, every frame, full quality.
- Scrubber shows rendered ranges like a buffering bar. Rendered ranges play smooth and fully swapped. Cached frames persist and are reused (re-seeking into a rendered range is instant).
- Un-rendered ranges fall back to Mode B so playback never stalls.
- Cost: about (video fps / 6.5) x real time, i.e. roughly 3.5-5 min of processing per minute of 24-30 fps video, per face, per swap pass.
- Pause/resume, cancel, and thermal-aware throttling (`ProcessInfo.thermalState`).

## Mode B: Reduced-rate live preview (instant, always available)
- Playback runs at real video speed. Swap about 6 frames/s (whatever the phone sustains) and hold each swapped frame until the next one is ready. Audio stays in sync.
- Face looks choppy but you see the result immediately after any seek. This is the fallback for un-rendered ranges and the "quick look" mode.

## Mode C: Swap every Nth frame + re-warp (EXPERIMENTAL, needs a quality test first)
- Detection is cheap (5 ms), so detect/track the face on EVERY frame. Keep the last swapped 128px patch; for in-between frames, re-align it with the current frame's landmarks and paste back (cheap, Metal).
- Smoother than B, but mouth/eye motion lags between swaps; may look uncanny on fast expressions.
- Gate: offline experiment first (Python reference pipeline on a short user-supplied clip, N = 2..5) and judge quality before building it into the app. Needs a short clip from the user (kept local, gitignored).

## Strength / identity pass count (from user's VisoMaster repo)
- VisoMaster "Strength" runs the swapper `itex = ceil(strength/100)` times; pass k feeds pass k-1's output back in with the SAME latent, then blends the final output with the previous pass by `alpha = (strength mod 100)/100` (alpha = 1 when it is an exact multiple). Verified in `kaiser62/visoswap` `visoswap/processors/workers/frame_worker.py` (lines ~434-456, 583-609). Higher strength = more source identity, fewer target expressions.
- Cost multiplies: strength 150 = 2 passes ~ 300 ms/frame. So: default 1 pass (100). Offer strength ONLY in Mode A / Phase 3 export, with a visible cost estimate. Not in Mode B/C live preview.
- Task: verify the effect on the test images in Python before building (1 vs 2 passes, alpha blend).

## Seek behaviour
- On seek: cancel in-flight work, flush tracker, show the raw frame immediately, resume Mode B at once and start Mode A from the new position.
- Scrubbing: raw frames while dragging; swap on release.

## Other
- Thermal state monitor: on `.serious`, lower the swap rate and tell the user.
- Keep screen awake while rendering; handle backgrounding (iOS suspends: pause render, resume on return).

## Tasks (advisor check after each)
2.0 Offline experiment: Mode C quality (needs a short clip) and strength 1 vs 2 passes on test images.
2.1 Pipeline core in Swift (reuse Phase 1) with golden-tensor tests against `tools/models/test/golden.npz` (local only).
2.2 Mode B player (AVPlayer + display from cache).
2.3 Mode A background renderer + ranges UI + seek handling.
2.4 Mode C if 2.0 says it is worth it.
2.5 Strength option for Mode A.

## Done when
- A 1080p clip plays with Mode B immediately after any seek, Mode A builds a visible rendered range that plays fully swapped, seeking never crashes, 5+ minutes tested for thermal behaviour.
- Measured rates recorded in `PROGRESS.md`.

## Optional later: lighter swap model
- Not chosen now. VisoMaster ships other swappers (SimSwap512, GhostFace v1/v2/v3, CSCS, InStyleSwapper256 A/B/C, DFM). Their FLOPs/licences are unchecked; revisit if the 6.5 swaps/s ceiling is not acceptable.
