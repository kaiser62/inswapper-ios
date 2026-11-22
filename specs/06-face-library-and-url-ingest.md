# Feature spec: face library + video from URL (added by user 2026-11-23, not started)

Two features the user asked to plan for next. Both build on the Phase 1 core; neither needs a new model.

## A. Video from a pasted URL (direct MP4)
- Paste a direct link to a video file (`.mp4` / `.mov` / `.m4v`) in the player's "Open" sheet; also keep "Pick from Files/Photos".
- Download with `URLSession` (background-capable `downloadTask`) into `Application Support/videos/`, with progress, cancel, resume, and a free-disk check against `Content-Length` before starting. Play and swap from the LOCAL file: `AVAssetReader` look-ahead and seeking need a file, and streaming would add nothing for Modes A/C.
- Scope limits: direct file URLs only. No page scraping, no yt-dlp-style extraction. HTTPS by default; plain HTTP only after an explicit per-URL confirmation (ATS exception needed for it).
- Video library list: downloaded videos with thumbnail, size, delete, "clear cache"; per-video persisted mode choice and rendered-patch cache (see spec 03) live next to the file.
- Decode at 720p max (spec 03 resolution decision), so large downloads still run.
- Validate after download: AVAsset is playable, has a video track, report fps/resolution/duration; reject otherwise.
- Test with the Mixkit stock URLs (direct `assets.mixkit.co/videos/<id>/<id>-720.mp4`).
- Rights note in the UI: personal use of content the user has the right to use.

## B. Face library (saved source identities)
- Save a source face once, pick it later from a grid instead of re-picking a photo. Entry = name + thumbnail + **latent (512 floats, already emap-applied)**; the original photo is NOT stored unless the user opts in (privacy, smaller storage; the latent is all the swapper needs).
- Multi-photo identities: let the user add several photos of one person; average the L2-normalised ArcFace embeddings BEFORE applying emap and re-normalising. Usually gives a more stable identity than one photo. Needs a check on the test images (does it help or blur?) before making it the default.
- Storage: `Application Support/faces/` (JSON index + `<id>.latent` + `<id>.jpg` thumbnail). Rename, delete, "export/import library" as a file for backup.
- Used everywhere a source is needed: Photo tab, video player, export. Per-video "which library face maps to which detected target face" comes later (multi-face video), start with one source for all selected target faces.
- Data stays on device; nothing face-derived goes in the repo or any external service. The library is app data, not part of `models.zip`.

## Order
Face library first (small, helps Photo tab immediately, needed by the player's source picker), URL ingest together with the video library when the Phase 2 player lands.
