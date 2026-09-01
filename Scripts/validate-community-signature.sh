#!/usr/bin/env bash
# Validate the fixed self-signed identity used by unnotarized community releases.
set -euo pipefail

expected_sha1="${1:-}"
expected_identifier="${2:-}"
[ -n "$expected_sha1" ] && [ -n "$expected_identifier" ] || {
  echo "usage: $0 CERTIFICATE_SHA1 BUNDLE_IDENTIFIER" >&2
  exit 64
}
expected_sha1="$(printf '%s' "$expected_sha1" | tr '[:upper:]' '[:lower:]')"
details="$(cat)"
expected_requirement="designated => identifier \"$expected_identifier\" and certificate leaf = H\"$expected_sha1\""

fail() {
  echo "community signature invalid: $1" >&2
  exit 1
}

printf '%s\n' "$details" | grep -Eq '(^|[[:space:]])flags=[^[:space:]]*\(runtime\)' \
  || fail "hardened runtime flag is missing"
printf '%s\n' "$details" | grep -Eq '(^|[[:space:]])flags=[^[:space:]]*\(adhoc,' \
  && fail "ad-hoc signing is forbidden for community releases"
printf '%s\n' "$details" | grep -Fxq 'Authority=Open Mouse Community Signing' \
  || fail "unexpected signing authority"
printf '%s\n' "$details" | grep -Fxq 'TeamIdentifier=not set' \
  || fail "community release must not claim an Apple Team identity"
printf '%s\n' "$details" | grep -Eq '^Authority=(Apple Development|Developer ID Application):' \
  && fail "Apple certificate identities must use their dedicated release path"
printf '%s\n' "$details" | grep -Fxq "$expected_requirement" \
  || fail "designated requirement is not pinned to the repository certificate and bundle id"

printf '%s\n' "$details" \
  | grep -E '^(Authority=Open Mouse Community Signing|TeamIdentifier=|designated =>)|flags=[^[:space:]]*\(runtime\)' >&2
