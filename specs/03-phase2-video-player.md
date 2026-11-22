# Phase 2: Video player with live swapping (main feature)

**Goal:** open a video, play and seek anywhere, frames are swapped during playback.

## Architecture
- `AVPlayer` is the audio/clock master. `AVPlayerItemVideoOutput` only yields frames at/near the playhead, so it can NOT read ahead; use it only for drop-frames mode.
- **Look-ahead mode:** a separate `AVAssetReader` decodes ahead of the player, the pipeline swaps each frame, and results are stored in a ring cache keyed by presentation timestamp. Display picks the cached frame matching the player clock (`CADisplayLink`) and renders to an `MTKView` (or `AVSampleBufferDisplayLayer`).
- `AVAssetReader` cannot seek: on every seek, cancel it and create a new reader with `timeRange` starting at the new position.
- Pipeline from Phase 1 runs per frame on a background queue.
- Face tracking: detect every N frames, track in between (landmark/box propagation), re-detect on tracking loss.
- Source embedding cached; changing the source face is allowed mid-playback.

## Modes
- **Look-ahead (default):** background queue swaps frames ahead of the playhead into a ring cache. Short buffering indicator after a seek, then smooth playback.
- **Real-time drop-frames:** keeps video clock; shows the latest swapped frame; may look choppy.
- Mode switch in UI.

## Seek behaviour
- On seek: cancel in-flight work, flush tracker + cache, show the raw frame immediately, detect fresh, resume swapping.
- Scrubbing: show raw frames while dragging, swap on release.

## Other
- Audio stays in sync (AVPlayer clock is the master).
- Thermal state monitor: when `.serious`, lower the swap rate or warn.
- Memory cap on cache.

## Done when
- A 1080p video plays with swapping and seeks to arbitrary points without crashing.
- Measured fps / buffering time recorded in `PROGRESS.md`.
- 5+ minute playback tested for thermal behaviour.
