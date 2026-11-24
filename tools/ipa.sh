#!/bin/bash
# Local unsigned IPA, same recipe as .github/workflows/build-ios.yml (LiveContainer re-signs it on install).
#   tools/ipa.sh         build build/InSwapBench.ipa
#   tools/ipa.sh -s      build, then serve it on the LAN and print the URL for LiveContainer > + > Install from URL
#   tools/ipa.sh -n -s   serve the IPA already built, no rebuild
# Env: BUILD=<number> sets the build number shown in Settings (default 9000, so local builds are told apart from CI's).
# Output: build/InSwapBench.ipa (build/ is gitignored). The IPA holds the app only: no models, faces or videos.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_IT=1; SERVE=0; PORT=8765
while getopts "ns" o; do case $o in n) BUILD_IT=0 ;; s) SERVE=1 ;; *) exit 2 ;; esac; done
W="$ROOT/build/ipa"; OUT="$ROOT/build/InSwapBench.ipa"

if [ $BUILD_IT = 1 ]; then
  rm -rf "$W"; mkdir -p "$W/InSwapBench"
  # Generate outside the source tree so the tracked project files stay clean; Info.plist must sit beside the project.
  ( cd "$ROOT/app" && GITHUB_RUN_NUMBER=${BUILD:-9000} xcodegen generate --spec project.yml --project "$W" >/dev/null )
  cp "$ROOT/app/InSwapBench/Info.plist" "$W/InSwapBench/Info.plist"
  xcodebuild archive -project "$W/InSwapBench.xcodeproj" -scheme InSwapBench -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$W/InSwapBench.xcarchive" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CURRENT_PROJECT_VERSION=${BUILD:-9000} 2>&1 \
    | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
  [ -d "$W/InSwapBench.xcarchive/Products/Applications/InSwapBench.app" ] || { echo "archive failed"; exit 1; }
  mkdir -p "$W/ipa/Payload"
  cp -R "$W/InSwapBench.xcarchive/Products/Applications/InSwapBench.app" "$W/ipa/Payload/"
  rm -f "$OUT"; ( cd "$W/ipa" && zip -qry "$OUT" Payload )
fi
[ -f "$OUT" ] || { echo "no IPA yet: run without -n first"; exit 1; }
ls -lh "$OUT"

if [ $SERVE = 1 ]; then
  IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  [ -n "$IP" ] || { echo "no LAN address found"; exit 1; }
  echo "Serving on http://$IP:$PORT/InSwapBench.ipa (Ctrl-C to stop). Phone must be on the same Wi-Fi."
  cd "$ROOT/build" && exec python3 -m http.server "$PORT" --bind "$IP"
fi
