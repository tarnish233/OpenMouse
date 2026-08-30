#!/usr/bin/env bash
# Assembles the SwiftPM executable into a real .app bundle and signs it.
#
# A menu bar app must be a bundle: LSUIElement, the bundle identifier that TCC keys the
# Accessibility grant on, and SMAppService login-item registration all live in Info.plist.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
APP_NAME="Open Mouse"
EXECUTABLE="OpenMouse"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"
[ -f "$BIN_PATH" ] || { echo "build product not found at $BIN_PATH" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# TCC remembers the Accessibility grant per (bundle id, code signature). Signing with a
# stable identity means the permission survives every rebuild; ad-hoc signatures change
# on each build and macOS then silently drops the grant.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
  IDENTITY_LABEL="$CODESIGN_IDENTITY"
else
  # Select by SHA-1 hash, not by name: a keychain commonly holds several certificates with
  # the identical "Apple Development: ..." common name, and codesign then refuses as
  # ambiguous. Revoked certificates are filtered out first.
  IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v CSSMERR \
    | grep -E '"(Apple Development|Developer ID Application)' \
    | head -1 || true)"
  IDENTITY="$(printf '%s' "$IDENTITY_LINE" | grep -oE '[0-9A-F]{40}' | head -1 || true)"
  IDENTITY_LABEL="$(printf '%s' "$IDENTITY_LINE" | grep -oE '"[^"]*"' | tr -d '"' || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> codesign with: ${IDENTITY_LABEL:-$IDENTITY} [$IDENTITY]"
  codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/    /'
else
  echo "==> codesign ad-hoc (no identity found; Accessibility permission may reset on rebuild)"
  codesign --force --sign - "$APP" 2>&1 | sed 's/^/    /'
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
echo "==> done: $APP"
