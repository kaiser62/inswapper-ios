# Phase 3: Offline export

**Goal:** render a full swapped video at full quality and speed-independent of playback.

## Scope
- `AVAssetReader` -> pipeline -> `AVAssetWriter` (HEVC/H.264), original audio passed through.
- Progress UI, cancel, background-safe where iOS allows (`beginBackgroundTask`; otherwise keep the screen awake and warn).
- Optional: slower quality settings here only (e.g. a face enhancer if it can be converted and is fast enough; otherwise skip).
- Save to Photos.

## Done when
- A 1-minute 1080p clip exports with correct audio sync and matches the look of live playback.
- Cancel and resume-from-failure handled cleanly.
