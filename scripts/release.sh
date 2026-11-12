#!/bin/bash
# Builds a distributable Tuff.app, zips it, and (optionally) signs the update for Sparkle.
#
#   scripts/release.sh                      # ad-hoc signed build → dist/Tuff-<version>.zip
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID scripts/release.sh
#
# Optional environment:
#   DEVELOPER_ID / TEAM_ID   sign with a Developer ID and enable the hardened runtime
#   NOTARY_PROFILE           `notarytool` keychain profile; if set, the zip is notarized and stapled
#   APPCAST_URL / SPARKLE_PUBLIC_KEY   override the values in project.yml
#   DOWNLOAD_URL_PREFIX      where the zips will be hosted (for generate_appcast)
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null

ARGS=(-project TuffBrowser.xcodeproj -scheme TuffBrowser -configuration Release -derivedDataPath build)
if [ -n "${DEVELOPER_ID:-}" ]; then
  ARGS+=("CODE_SIGN_IDENTITY=$DEVELOPER_ID" "DEVELOPMENT_TEAM=${TEAM_ID:?set TEAM_ID}" ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp")
fi
[ -n "${APPCAST_URL:-}" ] && ARGS+=("TUFF_APPCAST_URL=$APPCAST_URL")
[ -n "${SPARKLE_PUBLIC_KEY:-}" ] && ARGS+=("TUFF_SPARKLE_PUBLIC_KEY=$SPARKLE_PUBLIC_KEY")

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

# Sparkle's tools ship inside the SwiftPM checkout.
SPARKLE_BIN=$(find build/SourcePackages/artifacts -type d -path "*Sparkle/bin" 2>/dev/null | head -1)
if [ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
  if "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
    "$SPARKLE_BIN/generate_appcast" ${DOWNLOAD_URL_PREFIX:+--download-url-prefix "$DOWNLOAD_URL_PREFIX"} dist
    echo "Appcast: dist/appcast.xml — upload it, with the zip, to where TUFF_APPCAST_URL points."
  else
    echo "No Sparkle signing key yet. Create one with: $SPARKLE_BIN/generate_keys"
  fi
fi
