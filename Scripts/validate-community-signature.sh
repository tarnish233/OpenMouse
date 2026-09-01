#!/usr/bin/env bash
# Validate `codesign -dvvv` output for the stable self-signed community release.
set -euo pipefail

expected_authority="${1:-}"
expected_team="${2:-}"
details="$(cat)"

fail() {
  echo "community signature invalid: $1" >&2
  exit 1
}

case "$expected_authority" in
  "Apple Development:"*) ;;
  *) fail "expected signer is not an Apple Development identity" ;;
esac
printf '%s\n' "$details" | grep -Fxq "Authority=$expected_authority" \
  || fail "signer is not $expected_authority"
printf '%s\n' "$details" | grep -Eq '(^|[[:space:]])flags=[^[:space:]]*\(runtime\)' \
  || fail "hardened runtime flag is missing"
printf '%s\n' "$details" | grep -Eq '^Signature=adhoc$' \
  && fail "ad-hoc signatures do not provide a stable release identity"
if [ -z "$expected_team" ]; then
  fail "expected Apple Team identifier was not provided"
fi
printf '%s\n' "$details" | grep -Fxq "TeamIdentifier=$expected_team" \
  || fail "signer does not belong to Apple Team $expected_team"

printf '%s\n' "$details" | grep -E '^(Authority=|TeamIdentifier=)|flags=[^[:space:]]*\(runtime\)' >&2
