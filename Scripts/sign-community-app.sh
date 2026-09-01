#!/usr/bin/env bash
# Re-sign an assembled Open Mouse app with the repository-pinned self-signed identity.
# The private key lives only in the maintainer's login keychain.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source "$ROOT/Scripts/community-signing.sh"

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: $0 /path/to/Open\\ Mouse.app" >&2; exit 64; }
[ -d "$APP" ] || { echo "error: app bundle not found: $APP" >&2; exit 1; }
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
INFO="$APP/Contents/Info.plist"
[ -f "$INFO" ] || { echo "error: Info.plist missing: $INFO" >&2; exit 1; }

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
BUNDLE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")"
MAIN_EXECUTABLE="$APP/Contents/MacOS/$BUNDLE_EXECUTABLE"
UPDATER="$APP/Contents/Helpers/OpenMouseUpdater"
CERTIFICATE_SHA1="$(community_certificate_sha1 "$ROOT")"

[ -x "$MAIN_EXECUTABLE" ] || { echo "error: main executable missing: $MAIN_EXECUTABLE" >&2; exit 1; }
community_require_identity "$ROOT"

echo "==> fixed community identity: $COMMUNITY_SIGNING_CERTIFICATE_NAME [$CERTIFICATE_SHA1]"
if [ -f "$UPDATER" ]; then
  echo "==> signing update helper"
  community_sign_path "$ROOT" "$UPDATER" "$BUNDLE_IDENTIFIER.updater" 2>&1 | sed 's/^/    /'
fi

echo "==> signing application"
community_sign_path "$ROOT" "$APP" "$BUNDLE_IDENTIFIER" 2>&1 | sed 's/^/    /'

if [ -f "$UPDATER" ]; then
  community_verify_path "$ROOT" "$UPDATER" "$BUNDLE_IDENTIFIER.updater" 2>&1 | sed 's/^/    /'
fi
community_verify_path "$ROOT" "$APP" "$BUNDLE_IDENTIFIER" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
{
  printf '%s\n' "$SIGNATURE_DETAILS"
  printf '%s\n' "$DESIGNATED_REQUIREMENT"
} | "$ROOT/Scripts/validate-community-signature.sh" \
      "$CERTIFICATE_SHA1" "$BUNDLE_IDENTIFIER" 2>&1 \
    | sed 's/^/    /'
