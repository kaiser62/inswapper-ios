#!/bin/bash
# Local simulator build + UI screenshots (same -uiPreview screens as .github/workflows/screenshots.yml).
#   tools/sim.sh                         build, then shoot every screen at large text
#   tools/sim.sh player settings         only these screens
#   tools/sim.sh -x player library       at the largest accessibility text size
#   tools/sim.sh -l -x                   list screens / shoot all at xxl
# Options: -x xxl text (accessibility-extra-large, not the maximum), -n skip build, -l list screens, -d <device name>
# Output: build/sim-shots/<screen>_<large|xxl>.png (build/ is gitignored). Placeholder content only; no models, faces or videos.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENS="player photo library library-videos settings bench logs player-loaded player-empty player-settings player-video player-face player-theater player-ready library-exports export-sheet export-running export-paused export-done export-failed face-picker"
SIZE=large; TAG=large; BUILD=1; DEVICE="${SIM_DEVICE:-iPhone 18 Pro}"
while getopts "xnld:" o; do
  case $o in
    x) SIZE=accessibility-extra-large; TAG=xxl ;;
    n) BUILD=0 ;;
    l) echo $SCREENS | tr ' ' '\n'; exit 0 ;;
    d) DEVICE="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] && SCREENS="$*"

W="$ROOT/build/sim"; DD="$W/dd"; OUT="$ROOT/build/sim-shots"; BID=dev.kaiser62.inswapbench
mkdir -p "$W" "$OUT"
U=$(xcrun simctl list devices available | grep -E "^ +$DEVICE \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$U" ] || { echo "no simulator named '$DEVICE' (set SIM_DEVICE or -d)"; exit 1; }

if [ $BUILD = 1 ]; then
  # Generate outside the source tree so the tracked Info.plist is not touched; it must sit beside the project.
  ( cd "$ROOT/app" && GITHUB_RUN_NUMBER=${GITHUB_RUN_NUMBER:-0} xcodegen generate --spec project.yml --project "$W" >/dev/null )
  mkdir -p "$W/InSwapBench" && cp "$ROOT/app/InSwapBench/Info.plist" "$W/InSwapBench/Info.plist"
  xcodebuild -project "$W/InSwapBench.xcodeproj" -scheme InSwapBench -configuration Debug \
    -destination "platform=iOS Simulator,id=$U" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  [ -d "$DD/Build/Products/Debug-iphonesimulator/InSwapBench.app" ] || { echo "build failed"; exit 1; }
fi

xcrun simctl bootstatus "$U" -b >/dev/null 2>&1 || { xcrun simctl boot "$U" 2>/dev/null || true; xcrun simctl bootstatus "$U" -b >/dev/null; }
xcrun simctl install "$U" "$DD/Build/Products/Debug-iphonesimulator/InSwapBench.app"
xcrun simctl status_bar "$U" override --time 9:41 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
xcrun simctl ui "$U" appearance dark; xcrun simctl ui "$U" content_size "$SIZE"
for s in $SCREENS; do
  xcrun simctl launch --terminate-running-process "$U" "$BID" -uiPreview "$s" >/dev/null
  sleep 3   # the first launch after install draws late
  xcrun simctl io "$U" screenshot "$OUT/${s}_${TAG}.png" >/dev/null 2>&1
  echo "$OUT/${s}_${TAG}.png"
done
