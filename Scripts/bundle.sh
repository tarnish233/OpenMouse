#!/usr/bin/env bash
# Assembles the SwiftPM executable into a real .app bundle and signs it.
#
# A menu bar app must be a bundle: LSUIElement, the bundle identifier that TCC keys the
# Accessibility grant on, and SMAppService login-item registration all live in Info.plist.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source "$ROOT/Scripts/community-signing.sh"
CONFIG="${CONFIG:-release}"
DISTRIBUTION="${DISTRIBUTION:-0}"
COMMUNITY_DISTRIBUTION="${COMMUNITY_DISTRIBUTION:-0}"
DEBUG_VARIANT="${DEBUG_VARIANT:-0}"
EXECUTABLE="OpenMouse"
UPDATER_EXECUTABLE="OpenMouseUpdater"
OUT_DIR="${OUT_DIR:-$ROOT/build}"

if [ "$DEBUG_VARIANT" = "1" ]; then
  APP_NAME="Open Mouse Debug"
  BUNDLE_IDENTIFIER="com.openmouse.OpenMouse.debug"
  BUNDLE_EXECUTABLE="OpenMouseDebug"
else
  APP_NAME="Open Mouse"
  BUNDLE_IDENTIFIER="com.openmouse.OpenMouse"
  BUNDLE_EXECUTABLE="$EXECUTABLE"
fi
APP="$OUT_DIR/$APP_NAME.app"

if [ "$DEBUG_VARIANT" = "1" ]   && { [ "$DISTRIBUTION" = "1" ] || [ "$COMMUNITY_DISTRIBUTION" = "1" ]; }; then
  echo "error: Debug variant cannot be used for a distribution build" >&2
  exit 1
fi

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

cp "$BIN_PATH" "$APP/Contents/MacOS/$BUNDLE_EXECUTABLE"
cp "$UPDATER_BIN_PATH" "$APP/Contents/Helpers/$UPDATER_EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BUNDLE_EXECUTABLE" "$APP/Contents/Info.plist"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ] \
  && cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# TCC keys Accessibility/Input Monitoring grants to the bundle identifier plus the code's
# designated requirement. Public community builds use a repository-pinned self-signed
# certificate and an explicit requirement containing that certificate's SHA-1. Unlike ad-hoc
# CDHash requirements, this remains identical when the executable changes between versions.
USE_FIXED_COMMUNITY_IDENTITY=0
IDENTITY=""
IDENTITY_LABEL=""

if [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
  USE_FIXED_COMMUNITY_IDENTITY=1
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
  IDENTITY_LABEL="$CODESIGN_IDENTITY"
else
  # Prefer a real Developer ID when it exists. Never auto-select Apple Development: revoked or
  # development-only certificates can produce a bundle that verifies locally but is rejected on
  # another Mac. If Developer ID is unavailable, use the fixed community identity when installed;
  # this also keeps Debug builds' TCC authorization stable on maintainer machines.
  IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v CSSMERR \
    | grep -E '"Developer ID Application' \
    | head -1 || true)"
  IDENTITY="$(printf '%s' "$IDENTITY_LINE" | grep -oE '[0-9A-F]{40}' | head -1 || true)"
  IDENTITY_LABEL="$(printf '%s' "$IDENTITY_LINE" | grep -oE '"[^"]*"' | tr -d '"' || true)"
  if [ -z "$IDENTITY" ] && community_identity_available "$ROOT"; then
    USE_FIXED_COMMUNITY_IDENTITY=1
  fi
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

if [ "$USE_FIXED_COMMUNITY_IDENTITY" = "1" ]; then
  if [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
    echo "==> community signing: fixed self-signed identity + hardened runtime"
  else
    echo "==> local signing: fixed community identity (stable TCC requirement)"
  fi
  "$ROOT/Scripts/sign-community-app.sh" "$APP"
else
  if [ -n "$IDENTITY" ]; then
    echo "==> codesign with: ${IDENTITY_LABEL:-$IDENTITY} [$IDENTITY]"
    if [ "$DISTRIBUTION" = "1" ]; then
      echo "==> distribution signing: hardened runtime + secure timestamp"
    else
      echo "==> local identity signing: hardened runtime"
    fi
  else
    echo "==> codesign ad-hoc (Accessibility/Input Monitoring may reset for this rebuild)"
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
fi
if [ "$DISTRIBUTION" = "1" ] || [ "$COMMUNITY_DISTRIBUTION" = "1" ]; then
  echo "==> smoke-testing signed release executables"
  "$APP/Contents/MacOS/$BUNDLE_EXECUTABLE" --self-check >/dev/null
  "$APP/Contents/Helpers/$UPDATER_EXECUTABLE" --self-check >/dev/null
fi
echo "==> done: $APP"
