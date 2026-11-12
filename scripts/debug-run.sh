#!/bin/bash
# Runs the Debug build with a throwaway profile and a DebugHooks script (see Support/DebugHooks.swift).
#   scripts/debug-run.sh "wait 1; open https://example.com; wait 3; snap /tmp/a.png; quit"
#   scripts/debug-run.sh path/to/script.txt        # one command per line
# Env: TUFF_DATA_DIR (default: a fresh temp dir), TUFF_DEBUG_LOG (default: $TUFF_DATA_DIR/debug.log)
set -euo pipefail
SCRIPT="$1"
if [ -f "$SCRIPT" ]; then SCRIPT="$(cat "$SCRIPT")"; fi
cd "$(dirname "$0")/.."
APP="build/Build/Products/Debug/Tuff.app/Contents/MacOS/Tuff"
[ -x "$APP" ] || { echo "Build first: make build" >&2; exit 1; }
export TUFF_DATA_DIR="${TUFF_DATA_DIR:-$(mktemp -d -t tuff-test)}"
export TUFF_DEBUG_LOG="${TUFF_DEBUG_LOG:-$TUFF_DATA_DIR/debug.log}"
export TUFF_DEBUG_SCRIPT="$SCRIPT"
: > "$TUFF_DEBUG_LOG"
"$APP" >/dev/null 2>&1 || true
cat "$TUFF_DEBUG_LOG"
