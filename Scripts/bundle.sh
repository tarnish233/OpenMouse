#!/usr/bin/env bash
# Assembles the SwiftPM executable into a real .app bundle and signs it.
#
# A menu bar app must be a bundle: LSUIElement, the bundle identifier that TCC keys the
# Accessibility grant on, and SMAppService login-item registration all live in Info.plist.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"
DISTRIBUTION="${DISTRIBUTION:-0}"
COMMUNITY_DISTRIBUTION="${COMMUNITY_DISTRIBUTION:-0}"
APP_NAME="Open Mouse"
EXECUTABLE="OpenMouse"
UPDATER_EXECUTABLE="OpenMouseUpdater"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP="$OUT_DIR/$APP_NAME.app"

if [ "$DISTRIBUTION" = "1" ] && [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
  echo "error: Developer ID and community distribution modes are mutually exclusive" >&2
  exit 1
fi

if [ "$DISTRIBUTION" = "1" ] && [ -z "${CODESIGN_IDENTITY:-}" ]; then
  echo "error: make dist requires an explicit Developer ID Application identity" >&2
  echo "       use: CODESIGN_IDENTITY=<certificate SHA-1> make dist" >&2
  exit 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"
UPDATER_BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$UPDATER_EXECUTABLE"
[ -f "$BIN_PATH" ] || { echo "build product not found at $BIN_PATH" >&2; exit 1; }
[ -f "$UPDATER_BIN_PATH" ] || { echo "updater product not found at $UPDATER_BIN_PATH" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

# The icon and its vector drawing source are both tracked. Rebuild the asset if it is missing
# or the drawing source is newer, so a fresh source-only checkout remains reproducible.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ] \
  || [ "$ROOT/Scripts/make_icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]; then
  echo "==> generating AppIcon.icns"
  swift "$ROOT/Scripts/make_icon.swift"
fi

cp "$BIN_PATH" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$UPDATER_BIN_PATH" "$APP/Contents/Helpers/$UPDATER_EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ] \
  && cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# TCC remembers the Accessibility grant per (bundle id, code signature). Only a Developer ID
# identity is both stable across releases and valid for distribution without a development
# provisioning profile. Community releases therefore use an explicit ad-hoc signature: they
# remain launchable after the normal Gatekeeper override, but upgrades may reset TCC grants.
if [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
  IDENTITY=""
  IDENTITY_LABEL=""
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
  IDENTITY_LABEL="$CODESIGN_IDENTITY"
else
  # A Developer ID identity is stable and launchable without a provisioning profile. Do not
  # auto-select Apple Development here: revoked/expired development certificates can still be
  # listed as usable by `find-identity`, produce a bundle that passes `codesign --verify`, and
  # then be rejected by AMFI at launch. Distribution never enters this branch because it must
  # name an explicit Developer ID identity.
  IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v CSSMERR \
    | grep -E '"Developer ID Application' \
    | head -1 || true)"
  IDENTITY="$(printf '%s' "$IDENTITY_LINE" | grep -oE '[0-9A-F]{40}' | head -1 || true)"
  IDENTITY_LABEL="$(printf '%s' "$IDENTITY_LINE" | grep -oE '"[^"]*"' | tr -d '"' || true)"
fi

sign_component() {
  local path="$1"
  if [ -n "$IDENTITY" ]; then
    if [ "$DISTRIBUTION" = "1" ]; then
      codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
    else
      codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$path"
    fi
  else
    codesign --force --options runtime --sign - "$path"
  fi
}

if [ -n "$IDENTITY" ]; then
  echo "==> codesign with: ${IDENTITY_LABEL:-$IDENTITY} [$IDENTITY]"
  if [ "$DISTRIBUTION" = "1" ]; then
    echo "==> distribution signing: hardened runtime + secure timestamp"
  else
    echo "==> local identity signing: hardened runtime"
  fi
else
  # Keep the ad-hoc designated requirement tied to this exact build's CDHash. A weaker,
  # identifier-only requirement would make TCC permissions transferable to any replacement
  # bundle using the same identifier.
  if [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
    echo "==> community signing: ad-hoc + hardened runtime (manual upgrade; TCC grants may reset)"
  else
    echo "==> codesign ad-hoc (Accessibility/Input Monitoring may reset for this rebuild)"
  fi
fi

echo "==> signing update helper"
sign_component "$APP/Contents/Helpers/$UPDATER_EXECUTABLE" 2>&1 | sed 's/^/    /'
echo "==> signing application"
sign_component "$APP" 2>&1 | sed 's/^/    /'

codesign --verify --strict --verbose=1 "$APP/Contents/Helpers/$UPDATER_EXECUTABLE" 2>&1 | sed 's/^/    /'
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
if [ "$DISTRIBUTION" = "1" ]; then
  echo "==> validating distribution signature"
  SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
  printf '%s\n' "$SIGNATURE_DETAILS" | "$ROOT/Scripts/validate-distribution-signature.sh" 2>&1 \
    | sed 's/^/    /'
fi
if [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
  echo "==> validating community signature"
  SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
  printf '%s\n' "$SIGNATURE_DETAILS" \
    | "$ROOT/Scripts/validate-community-signature.sh" 2>&1 \
    | sed 's/^/    /'
fi
if [ "$DISTRIBUTION" = "1" ] || [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
  echo "==> smoke-testing signed release executables"
  "$APP/Contents/MacOS/$EXECUTABLE" --self-check >/dev/null
  "$APP/Contents/Helpers/$UPDATER_EXECUTABLE" --self-check >/dev/null
fi
echo "==> done: $APP"
