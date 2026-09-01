#!/usr/bin/env bash
# Import the same encrypted Open Mouse community identity on a second maintainer Mac.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
source "$ROOT/Scripts/community-signing.sh"

P12="${1:-}"
[ -f "$P12" ] || {
  echo "usage: $0 /secure/path/OpenMouseCommunitySigning.p12" >&2
  exit 64
}
LOGIN_KEYCHAIN="$(security default-keychain -d user \
  | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
EXPECTED_SHA1="$(community_certificate_sha1 "$ROOT")"
CERTIFICATE_FILE="$(community_certificate_file "$ROOT")"

if community_identity_available "$ROOT"; then
  echo "identity already installed: $COMMUNITY_SIGNING_CERTIFICATE_NAME [$EXPECTED_SHA1]"
  exit 0
fi

printf 'PKCS#12 password: ' >&2
IFS= read -r -s P12_PASSWORD
printf '\n' >&2
[ -n "$P12_PASSWORD" ] || { echo "error: empty password" >&2; exit 1; }
security import "$P12" -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -f pkcs12 >/dev/null
unset P12_PASSWORD

# This creates a persistent trust entry for Code Signing only. macOS requires the local user to
# approve the change; it does not grant SSL or email trust to this certificate.
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_FILE"

community_require_identity "$ROOT"
ACTUAL_SHA1="$(security find-certificate -Z \
  -c "$COMMUNITY_SIGNING_CERTIFICATE_NAME" "$LOGIN_KEYCHAIN" \
  | awk '/SHA-1 hash:/{print $3; exit}')"
[ "$ACTUAL_SHA1" = "$EXPECTED_SHA1" ] || {
  echo "error: imported certificate fingerprint mismatch" >&2
  exit 1
}
echo "imported: $COMMUNITY_SIGNING_CERTIFICATE_NAME [$ACTUAL_SHA1]"
