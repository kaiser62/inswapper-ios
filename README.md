# InSwap

A face-swap video player and photo swapper that runs entirely on an iPhone. It swaps faces with InSwapper (`inswapper_128`) through Core ML on the Neural Engine, with no server and no network at swap time. Built for personal use on an iPhone 14 Pro (A16, iOS 17+).

> **Status: pre-release (0.1).** Builds are unsigned and published as pre-releases. Expect rough edges.

## What it does

- **Player:** pick a video (Photos, Files, or a saved link) and a saved face, then watch it swapped.
  - **Live:** swaps while you watch. Instant after a seek; the face lags a little on fast motion.
  - **Render ahead:** swaps every frame in the background. Green parts of the timeline are ready to play perfectly.
  - Scrub, skip 5 s, playback speed, swap on/off comparison, theater mode.
- **Export:** renders the whole clip with the swap and encodes it to a video you can save or share. Pause and resume, and rendered frames are kept if you cancel.
- **Photo:** swap faces in still photos, with per-face selection for group shots.
- **Library:** saved faces (1-8 photos per person, averaged into one identity), saved videos, and past exports. Face backup and restore.

Only a 512-number face identity and a small thumbnail are kept for each saved face, not the original photos.

## Speed

Measured on an iPhone 14 Pro:

| Swapper | Swaps per second |
|---|---|
| FP16 | about 6.8 |
| 8-bit palettized (`swapper_pal8`) | about 15 to 16 |

The Neural Engine runs one swap at a time. Running 2 to 4 swappers in parallel gave no gain (1.01x to 1.06x), so the speed levers are a cheaper model and fewer swaps, not more threads. Details are in [specs/PROGRESS.md](specs/PROGRESS.md) and [specs/perf-research.md](specs/perf-research.md).

## Install

Builds are unsigned IPAs that a sideloading app re-signs, tested with [LiveContainer](https://github.com/LiveContainer/LiveContainer).

1. Download the newest IPA from [Releases](https://github.com/kaiser62/inswapper-ios/releases). The rolling `latest` release always holds the newest build; the `v0.1-pre.N` releases are snapshots.
   `https://github.com/kaiser62/inswapper-ios/releases/download/latest/InSwapBench.ipa`
2. In LiveContainer: **Apps**, **+**, **Install from URL**, paste the link. If asked, choose to replace the existing app to keep your data.
3. Open the app, then **Settings**, **Models and benchmark**, and import `models.zip` (see below).

Settings shows the build number.

## Models

The model weights are **not** in this repo. They are large (about 550 MB) and the InSwapper and insightface weights are for non-commercial use. You convert them yourself, on your own Mac:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/convert.py all      # ONNX weights in tools/models/ -> Core ML packages
python tools/package_models.py   # -> models.zip (+ manifest, emap.bin)
```

Put `inswapper_128.onnx` and the insightface `buffalo_l` detector and recognizer ONNX files in `tools/models/` first (see [specs/01-phase0-spike.md](specs/01-phase0-spike.md)).

Send `models.zip` to the phone (AirDrop or iCloud Drive) and import it in the app. An optional `swapper_pal8.zip` adds the faster 8-bit swapper (`python tools/compress_exp.py pal8`). Conversion never runs in CI, because the repo is public.

## Build

CI (GitHub Actions, macOS runner) generates the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen), builds an unsigned Release archive, and publishes the IPA. To do the same locally:

```bash
tools/ipa.sh        # unsigned IPA at build/InSwapBench.ipa (about 30 s)
tools/ipa.sh -s     # also serve it on your Wi-Fi for LiveContainer's Install from URL
tools/sim.sh        # build for the simulator and screenshot every screen (build/sim-shots/)
```

Local builds are numbered 9000 unless you set `BUILD=<n>`. Requires Xcode and `brew install xcodegen`.

## Repo layout

| Path | What is in it |
|---|---|
| `app/Core/` | Pipeline: detection, alignment, swap, patch cache, Metal compositor, player and export engines. Plain Swift, unit-tested in CI without models. |
| `app/InSwapBench/` | SwiftUI app: Player, Photo, Library, Settings, and a benchmark screen. |
| `app/project.yml` | XcodeGen project definition. |
| `specs/` | Design notes by phase, [PROGRESS.md](specs/PROGRESS.md) (the build-by-build log, including device checks), and perf research. |
| `tools/` | Model conversion and packaging, benchmarks and check harnesses, `ipa.sh`, `sim.sh`. |
| `.github/workflows/` | `build-ios` (IPA and release) and `screenshots` (simulator screenshots). |

## Licence and use

Personal use only. The code here has no licence granted for reuse yet. The model weights keep their own non-commercial terms. Do not swap anyone's face without their consent.
