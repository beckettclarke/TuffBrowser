#!/bin/bash
# Builds a distributable Tuff.app and zips it (optionally signed and notarized).
#
#   scripts/release.sh                      # ad-hoc signed build → dist/Tuff-<version>.zip
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID scripts/release.sh
#
# Optional environment:
#   DEVELOPER_ID / TEAM_ID   sign with a Developer ID and enable the hardened runtime
#   NOTARY_PROFILE           `notarytool` keychain profile; if set, the zip is notarized and stapled
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null

ARGS=(-project TuffBrowser.xcodeproj -scheme TuffBrowser -configuration Release -derivedDataPath build)
if [ -n "${DEVELOPER_ID:-}" ]; then
  ARGS+=("CODE_SIGN_IDENTITY=$DEVELOPER_ID" "DEVELOPMENT_TEAM=${TEAM_ID:?set TEAM_ID}" ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp")
fi

xcodebuild "${ARGS[@]}" build | grep -E "error|warning: |BUILD" || true

APP="build/Build/Products/Release/Tuff.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/Tuff-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "App:  $(du -sh "$APP" | cut -f1)   ($APP)"
echo "Zip:  $(du -sh "$ZIP" | cut -f1)   ($ZIP)"

