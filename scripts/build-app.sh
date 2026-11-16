#!/bin/bash
# Build PhoneBridge.app into ./build and optionally install it.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/PhoneBridge.app"

swift build -c release --product PhoneBridge
BIN="$(swift build -c release --show-bin-path)/PhoneBridge"

if [ -d "$APP" ]; then rm -r "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhoneBridge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi

# Signing. macOS keys privacy permissions (camera) to the signature; an ad-hoc signature
# changes on every build, so the camera prompt would come back after each rebuild.
# Use PB_SIGN_IDENTITY if set, else the first local "Apple Development" identity, else ad-hoc.
# This is local signing only; distributing builds needs a Developer ID + notarization.
IDENTITY="${PB_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ {print $2; exit}')"
fi
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [ "${1:-}" = "--install" ]; then
  if pgrep -x PhoneBridge >/dev/null; then osascript -e 'quit app "PhoneBridge"' || true; sleep 1; fi
  if [ -d /Applications/PhoneBridge.app ]; then rm -r /Applications/PhoneBridge.app; fi
  cp -R "$APP" /Applications/
  echo "Installed /Applications/PhoneBridge.app"
fi
