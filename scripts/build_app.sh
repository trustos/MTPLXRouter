#!/bin/bash
# Assemble "MTPLX Router.app" (a menu-bar / LSUIElement app) around the SPM binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"

echo "▸ swift build -c $CONFIG"
( cd "$ROOT" && swift build -c "$CONFIG" )

BIN="$ROOT/.build/$CONFIG/MTPLXRouter"
APP="$ROOT/dist/MTPLX Router.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MTPLXRouter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so launch services / SMAppService behave on this machine.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "▸ Built: $APP"
echo "  Run:   open \"$APP\""
echo "  For launch-at-login, move it to /Applications and enable it from the menu."
