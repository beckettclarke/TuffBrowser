#!/bin/bash
# Builds a distributable Tuff.app and zips it (optionally signed and notarized), plus a DMG to
# hand to people.
#
#   scripts/release.sh                      # ad-hoc signed build → dist/Tuff-<version>.zip, dist/Tuff.dmg
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID scripts/release.sh
#   PUBLISH=1 scripts/release.sh            # …and ship it to everyone through the in-app updater
#   MARKETING_VERSION=0.2.0-nightly.20261118 PUBLISH=1 scripts/release.sh   # a nightly
#
# Optional environment:
#   DEVELOPER_ID / TEAM_ID   sign with a Developer ID and enable the hardened runtime
#   NOTARY_PROFILE           `notarytool` keychain profile; if set, the zip is notarized and stapled
#   MARKETING_VERSION        overrides project.yml's version for this build. Nightlies carry a
#                            sortable suffix and count up to the *next* version: 0.2.0-nightly.<date>
#   PUBLISH                  if set, creates the GitHub release v<version> with the zip, which Flint
#                            (the updater) offers to users. Needs `gh`; NOTES=file.md for the notes
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null

ARGS=(-project TuffBrowser.xcodeproj -scheme TuffBrowser -configuration Release -derivedDataPath build)
if [ -n "${MARKETING_VERSION:-}" ]; then
  ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
fi
if [ -n "${DEVELOPER_ID:-}" ]; then
  ARGS+=("CODE_SIGN_IDENTITY=$DEVELOPER_ID" "DEVELOPMENT_TEAM=${TEAM_ID:?set TEAM_ID}" ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp")
fi

xcodebuild "${ARGS[@]}" build | grep -E "error|warning: |BUILD" || true

APP="build/Build/Products/Release/Tuff.app"
# Xcode never updates the .app folder's own date, and macOS caches icons by it: a stale date
# makes an updated app keep showing an older build's icon.
touch "$APP"
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

# The DMG keeps one name, so .../releases/latest/download/Tuff.dmg always gets the newest.
DMG="dist/Tuff.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Tuff.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Tuff" -srcfolder "$STAGE" -fs HFS+ -format ULFO "$DMG"

echo "App:  $(du -sh "$APP" | cut -f1)   ($APP)"
echo "Zip:  $(du -sh "$ZIP" | cut -f1)   ($ZIP)"
echo "DMG:  $(du -sh "$DMG" | cut -f1)   ($DMG)"

if [ -n "${PUBLISH:-}" ]; then
  # Flint compares the tag with the app's CFBundleShortVersionString and picks Tuff-*.zip;
  # the DMG is for people installing by hand.
  # Suffixed versions (0.2.0-nightly.…) are pre-releases: only the nightly channel gets them.
  GH=(--title "Tuff $VERSION")
  if [[ $VERSION == *-* ]]; then GH+=(--prerelease); fi
  if [ -n "${NOTES:-}" ]; then GH+=(--notes-file "$NOTES"); else GH+=(--generate-notes); fi
  gh release create "v$VERSION" "$ZIP" "$DMG" "${GH[@]}"
fi

