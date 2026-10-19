#!/bin/bash
# Builds Tangelo.app into ./build. With --install, copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "› Building (release)…"
swift build -c release --product Tangelo
swift build -c release --product tangelo-cli

[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources/AppIcon.icns

APP=build/Tangelo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/Tangelo "$APP/Contents/MacOS/Tangelo"
# Conversions run in this helper (tangelo-cli job) so their frameworks never stay resident in the app.
# It lives in Contents/Helpers with its own embedded Info.plist (app.tangelo.mac.worker, background-only).
cp .build/release/tangelo-cli "$APP/Contents/Helpers/tangelo-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"
cp .build/release/tangelo-cli build/tangelo-cli

# Ad-hoc signature (required on Apple Silicon; the app is built locally so Gatekeeper doesn't quarantine it).
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  if pgrep -x Tangelo >/dev/null; then
    echo "› Quitting the running Tangelo…"
    osascript -e 'tell application id "app.tangelo.mac" to quit' >/dev/null 2>&1 || pkill -x Tangelo || true
    sleep 1
  fi
  rm -rf "$DEST/Tangelo.app"
  cp -R "$APP" "$DEST/"
  echo "✓ Installed to $DEST/Tangelo.app"
  open "$DEST/Tangelo.app"
  echo "✓ Launched — look for the citrus icon in your menu bar."
fi
