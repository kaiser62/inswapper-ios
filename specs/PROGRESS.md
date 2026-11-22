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
- Note: claude-mem observer credentials were failing (needs `/login`); this folder is the source of truth for continuing.
