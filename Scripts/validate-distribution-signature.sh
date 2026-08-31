#!/usr/bin/env bash
# Validate the text emitted by `codesign -dvvv <app>` for a release artifact.
set -euo pipefail

details="$(cat)"

fail() {
  echo "distribution signature invalid: $1" >&2
  exit 1
}

printf '%s\n' "$details" | grep -Eq '^Authority=Developer ID Application:' \
  || fail "signer is not Developer ID Application"
printf '%s\n' "$details" | grep -Eq '^Timestamp=.+' \
  || fail "secure timestamp is missing"
printf '%s\n' "$details" | grep -Eq '(^|[[:space:]])flags=[^[:space:]]*\(runtime\)' \
  || fail "hardened runtime flag is missing"

printf '%s\n' "$details" | grep -E '^(Authority=Developer ID Application:|TeamIdentifier=|Timestamp=)|flags=[^[:space:]]*\(runtime\)' >&2
