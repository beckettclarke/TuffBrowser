#!/bin/bash
# Prints the xcodebuild settings that sign Tuff with a real certificate, when the keychain has
# one of the wanted kind; prints nothing otherwise, and the build is signed ad hoc as
# project.yml says.
#
# Why it matters: apps that pair with a browser check its code signature first. 1Password's
# desktop app, for one, only accepts browsers signed with a Developer ID (or shipped through
# the App Store) — an ad hoc or "Apple Development" signature is turned away with "signed in
# an unsupported way".
#
#   SIGN_KIND   certificate kind to look for (default: "Developer ID Application").
#               SIGN_KIND="Apple Development" gives local builds a stable identity, so macOS
#               stops re-asking for camera / microphone access after every rebuild.
set -euo pipefail
kind="${SIGN_KIND:-Developer ID Application}"
name=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' -v kind="$kind" 'index($2, kind) == 1 { print $2; exit }')
[ -n "$name" ] || exit 0
# The team ID is the certificate's organisational unit (the code in the name is not it).
team=$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
[ -n "$team" ] || exit 0
printf 'CODE_SIGN_IDENTITY="%s" DEVELOPMENT_TEAM=%s\n' "$kind" "$team"
