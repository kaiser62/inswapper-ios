# Phase 2: Video player with swapping (REWRITTEN 2026-11-23 after device benchmark)

**Why rewritten:** measured swapper = 150 ms/frame on iPhone 14 Pro (~6.5 swaps/s). Video-rate (24-30 fps) live swapping is not achievable with inswapper_128. User wants three modes, each SELECTABLE on its own (a mode picker), and also usable together where it makes sense (see below).

**Goal:** open a video, play and seek anywhere, and get swapped faces as fast as the phone allows, with honest feedback about what is ready.

## Resolution target (user decision 2026-11-23)
720p is the default working/display resolution; 1080p is considered too heavy for the phone for now. Decode/composite at 720p (downscale larger sources at decode via the reader's output settings); 1080p+ becomes an optional later setting. Patch cache size is unaffected (128 px patches). Raw 720p BGRA frame = ~3.7 MB.

## Mode selection (user request 2026-11-23)
Each mode is an independent, user-selectable option in a player mode picker; none requires another to work. The picker shows each mode's trade-off (smoothness vs wait vs expression accuracy) and the current measured swap rate.
- **A: Background render** works standalone: when selected, un-rendered ranges show the RAW video (no swapping) with a "rendering..." indicator instead of falling back to B.
- **B: Reduced-rate live preview** works standalone: no cache needed beyond the last swapped frame.
- **C: Re-warp (Nth-frame swap)** works standalone once built (still gated by task 2.0).
- Optional combo toggle: "A + B fallback" (A with B filling un-rendered ranges), off by default; the user picks.
- The chosen mode and its options persist per video; switching modes mid-playback keeps the position and any already-rendered cache.

## Shared architecture (revised after advisor review 2026-11-23)
- `AVPlayer` = audio + clock master. The display frame is always the RAW frame from `AVPlayerItemVideoOutput` at the playhead, composited on the GPU (`MTKView`) with a swapped face PATCH. The video itself never stutters; only the patch source differs per mode.
- **Cache the patch, not the frame.** For each presentation timestamp (PTS) store: the 128x128 RGB swapped patch (~49 KB) + its 2x3 alignment matrix M (+ face id). ~88 MB per minute at 30 fps, so it can persist to disk per video. (Full swapped 1080p BGRA frames would be ~8.3 MB each, ~15 GB per minute: rejected.)
- **One Metal compositor** (inverse-warp patch by M, feathered mask, blend onto the raw frame). The paste-back mask depends only on M and frame size (insightface's diff mask is computed and then discarded), so it is built in the shader: warped white square, eroded by `max(ms//10,10)`, blurred by `max(ms//20,5)`. The modes differ only in which patch/M they feed it:
  - A: the patch cached for that exact PTS (with its own M).
  - B: the latest available patch, pasted at that patch's own M.
  - C: the latest patch pasted with the CURRENT frame's M (fresh detection each frame). A canonical-coordinate patch + fresh M is exactly the re-warp.
- A separate `AVAssetReader` decodes frames for the swap worker. It cannot seek: on every seek, cancel and recreate it with `timeRange` from the new position.
- Per swapped frame: letterbox -> SCRFD (5 ms) -> align (Umeyama, +8 template) -> swapper (150 ms) -> store patch+M. Source embedding + `emap` latent computed once per source face.
- Pipeline code is frame-in/patch-out (`CVPixelBuffer` in) and shared with Phase 1 (photo) and Phase 3 (export; export uses the same compositor offline).
- Memory: cache holds patches only (~88 MB/min), persisted to disk per video; evict by a byte cap, furthest from the playhead first. Raw frames are never cached by us.

## Mode A: Background render from the playhead (PRIMARY, recommended)
- Seek anywhere: swapping starts at that point and runs ahead, every frame, full quality.
- Scrubber shows rendered ranges like a buffering bar. Rendered ranges play smooth and fully swapped. Cached frames persist and are reused (re-seeking into a rendered range is instant).
- Standalone behaviour: un-rendered ranges play the raw video with a "rendering..." indicator (or Mode B if the user enabled the optional A+B combo).
- Cost: about (video fps / 6.5) x real time, i.e. roughly 3.5-5 min of processing per minute of 24-30 fps video, per face, per swap pass.
- Pause/resume, cancel, and thermal-aware throttling (`ProcessInfo.thermalState`).

## Mode B: Reduced-rate live preview (instant, always available)
- Precisely: every displayed frame is the CURRENT raw frame (video and audio stay smooth) plus the latest finished patch pasted at that patch's own M. Only the face updates at ~6 Hz; it does not hold the whole frame.
- Latency compensation: the swap worker picks the source frame at playhead + measured pipeline latency (~160 ms, measured at runtime), so the patch arrives roughly on time instead of ~150 ms behind the audio.
- Shown immediately after any seek. Face lags/choppy on fast motion. This is the "quick look" mode and the optional fallback for un-rendered ranges.
- Note: B with the current frame's M instead of the patch's own M is Mode C. The real difference between B and C is whether the face is re-detected every frame.

## Mode C: Swap every Nth frame + re-warp (EXPERIMENTAL, needs a quality test first)
- Detection is cheap (5 ms), so detect/track the face on EVERY frame. Keep the last swapped 128px patch; for in-between frames, re-align it with the current frame's landmarks and paste back (cheap, Metal).
- Smoother than B, but mouth/eye motion lags between swaps; may look uncanny on fast expressions.
- Gate: offline experiment first (Python reference pipeline on a short user-supplied clip, N = 2..5) and judge quality before building it into the app. Needs a short clip from the user (kept local, gitignored).

## Strength / identity pass count (from user's VisoMaster repo)
- VisoMaster "Strength" runs the swapper `itex = ceil(strength/100)` times; pass k feeds pass k-1's output back in with the SAME latent, then blends the final output with the previous pass by `alpha = (strength mod 100)/100` (alpha = 1 when it is an exact multiple). Verified in `kaiser62/visoswap` `visoswap/processors/workers/frame_worker.py` (lines ~434-456, 583-609). Higher strength = more source identity, fewer target expressions.
- Cost multiplies: strength 150 = 2 passes ~ 300 ms/frame. So: default 1 pass (100). Offer strength ONLY in Mode A / Phase 3 export, with a visible cost estimate. Not in Mode B/C live preview.
- Task: verify the effect on the test images in Python before building (1 vs 2 passes, alpha blend).
- LICENCE: `kaiser62/visoswap` is GPL-3.0. Do NOT copy its code into this public repo; the strength idea is reimplemented here from the description above only.

## Task 2.0 RESULTS (2026-11-23, Python reference on the two Mixkit stock clips + test photo; `tools/exp_phase2.py`)
**Mode C re-warp** (face-region PSNR vs swapping EVERY frame, in-between frames only, mean / p10; raw unswapped is the floor):
| N | landscape clip C | B (stale M) | portrait clip C | B (stale M) |
|---|---|---|---|---|
| 2 | 37.1 / 33.2 | 36.8 / 34.4 | 31.4 / 25.9 | 28.7 / 24.7 |
| 4 | 34.2 / 28.7 | 33.2 / 28.7 | 28.4 / 23.1 | 25.2 / 20.0 |
| 6 | 32.0 / 27.2 | 31.0 / 25.8 | 26.4 / 20.8 | 22.8 / 17.6 |
| raw | 23.9 | | 27.9 | |
- 24 fps video at the measured ~6.5 swaps/s means N=4 is the realistic sustained setting. C beats B by ~1 dB on a near-static head and ~3 dB with head motion. On the portrait clip raw scores 27.9: C is only above raw up to N=4 (28.4) and falls below it from N=6; Mode B (stale M) is already below raw from N=3. PSNR is a weak proxy and re-warp cannot reproduce mouth/eye motion between swaps.
- Visual (worst-frame contact sheets): head pose/position are right, but mouth and eye state lag by up to N-1 frames (open vs closed mouth on speech). Acceptable for slow/neutral clips, visibly laggy on fast speech.
- Detector jitter (mean |2nd difference| of landmarks): 0.007 inter-eye (~1 px) on the near-static clip, 0.028 on the moving portrait clip (includes real acceleration): small, so the tracker needs only light smoothing.\n- N is not fixed: 24 fps with N=4 needs 6.0 swaps/s vs 6.6 measured with no decode/composite. Treat N as emergent (worker always takes the newest frame), expect an effective N of 4-6.\n- **Gate: the PSNR/still evidence is NOT decisive for Mode C (its artefacts are temporal). Side-by-side videos for the user to judge, each = raw | every-frame swap (Mode A quality) | Mode C | Mode B: `tools/models/test/cmp_stock_{2960,42323}_N{4,6}.mp4`. Mode C stays planned as experimental opt-in, pending the user's call.**

**Strength** (7 targets: test photo + 3 frames per clip; identity = ArcFace cos of the 112 crop vs the source; drift = mean landmark shift / inter-eye distance on the re-detected result):
| passes | identity cos | landmark drift |
|---|---|---|
| target (unswapped) | -0.02 | 0 |
| 100 (1) | 0.918 | 0.035 |
| 150 (blend .5) | 0.922 | 0.043 |
| 200 (2) | 0.924 | 0.050 |
| 300 (3) | 0.924 | 0.063 |
- The identity metric is INCONCLUSIVE: it uses the same ArcFace that produces the latent, so it saturates by construction. The drift rise (0.035 -> 0.063) agrees with the user's VisoMaster observation (more source identity, fewer target expressions). Judge visually: `tools/models/test/sheet_strength.png` (cols orig | 100 | 150 | 200 | 300). Each pass costs +150 ms/frame.
- The 'ghost beard' on the bearded clip is present in the raw 128 px swapper output (`patch_stock_2960.png`), so it is the swapper, not the paste-back mask.
- **Decision unchanged: Strength is an optional Mode A / export setting (default 1 pass), cost shown.**

## Seek behaviour
- On seek: cancel in-flight work, flush tracker, show the raw frame immediately, then continue in the selected mode (B: swap resumes at once; A: render restarts from the new position, optionally with B filling in if the combo is on; C: re-detect and warp).
- Scrubbing: raw frames while dragging; swap on release.

## Other
- Thermal state monitor: on `.serious`, lower the swap rate and tell the user.
- Keep screen awake while rendering; handle backgrounding (iOS suspends: pause render, resume on return).

## Tasks (advisor check after each)
2.0 DONE (see results above): Mode C passes as experimental opt-in; strength kept optional.
2.1 Pipeline core in Swift: DONE in Phase 1 step 1.1 (`app/Core`, verified vs golden on Mac). Remaining here: Metal compositor (same analytic mask math as `Compositor.swift`), patch cache, tracker.
2.2 Mode picker UI + Mode B player (AVPlayer + display from cache); each mode selectable separately.
2.3 Mode A background renderer + ranges UI + seek handling.
2.4 Mode C if 2.0 says it is worth it.
2.5 Strength option for Mode A.

## Done when
- A 1080p clip plays with Mode B immediately after any seek, Mode A builds a visible rendered range that plays fully swapped, seeking never crashes, 5+ minutes tested for thermal behaviour.
- Measured rates recorded in `PROGRESS.md`.

## Optional later: lighter swap model
- Not chosen now. VisoMaster ships other swappers (SimSwap512, GhostFace v1/v2/v3, CSCS, InStyleSwapper256 A/B/C, DFM). Their FLOPs/licences are unchecked; revisit if the 6.5 swaps/s ceiling is not acceptable.
