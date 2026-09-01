#!/usr/bin/env bash
# Shared facts and helpers for Open Mouse's fixed community code-signing identity.
# This file contains no private material; the repository tracks only the public certificate.

COMMUNITY_SIGNING_CERTIFICATE_NAME="Open Mouse Community Signing"
COMMUNITY_SIGNING_CERTIFICATE_RELATIVE_PATH="Resources/OpenMouseCommunitySigning.cer"

community_certificate_file() {
  local root="$1"
  printf '%s/%s\n' "$root" "$COMMUNITY_SIGNING_CERTIFICATE_RELATIVE_PATH"
}

community_certificate_sha1() {
  local root="$1"
  local certificate
  certificate="$(community_certificate_file "$root")"
  [ -f "$certificate" ] || {
    echo "error: community public certificate missing: $certificate" >&2
    return 1
  }
  openssl x509 -inform der -in "$certificate" -noout -fingerprint -sha1 \
    | cut -d= -f2 \
    | tr -d ':' \
    | tr '[:lower:]' '[:upper:]'
}

community_designated_requirement() {
  local root="$1" identifier="$2" sha1
  sha1="$(community_certificate_sha1 "$root" | tr '[:upper:]' '[:lower:]')"
  printf 'designated => identifier "%s" and certificate leaf = H"%s"\n' "$identifier" "$sha1"
}

community_identity_available() {
  local root="$1" sha1
  sha1="$(community_certificate_sha1 "$root")" || return 1
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -v CSSMERR \
    | grep -F "$sha1" \
    | grep -F "\"$COMMUNITY_SIGNING_CERTIFICATE_NAME\"" \
    >/dev/null
}

community_require_identity() {
  local root="$1" sha1
  sha1="$(community_certificate_sha1 "$root")"
  if ! community_identity_available "$root"; then
    cat >&2 <<EOF_MESSAGE
error: fixed community signing identity is unavailable
       expected: $COMMUNITY_SIGNING_CERTIFICATE_NAME [$sha1]
       import the encrypted OpenMouseCommunitySigning.p12 into the login keychain,
       then trust it for Code Signing only. Never create a replacement certificate.
EOF_MESSAGE
    return 1
  fi
}

community_sign_path() {
  local root="$1" path="$2" identifier="$3" sha1 requirement
  sha1="$(community_certificate_sha1 "$root")"
  requirement="$(community_designated_requirement "$root" "$identifier")"
  codesign --force --options runtime --timestamp=none \
    --identifier "$identifier" \
    --requirements "=$requirement" \
    --sign "$sha1" \
    "$path"
}

community_verify_path() {
  local root="$1" path="$2" identifier="$3" expected actual
  expected="$(community_designated_requirement "$root" "$identifier")"
  codesign --verify --strict --verbose=1 "$path"
  actual="$(codesign -d -r- "$path" 2>&1 | sed -n '/^designated =>/p')"
  [ -n "$actual" ] || {
    echo "error: no designated requirement found for $path" >&2
    return 1
  }
  [ "$actual" = "$expected" ] || {
    echo "error: unexpected designated requirement for $path" >&2
    echo "       expected: $expected" >&2
    echo "       actual:   $actual" >&2
    return 1
  }
  codesign --verify --strict --requirements "=$expected" "$path"
}
