#!/usr/bin/env bash
# Validate `codesign -dvvv` output for the launchable, unnotarized community release.
set -euo pipefail

details="$(cat)"

fail() {
  echo "community signature invalid: $1" >&2
  exit 1
}

printf '%s\n' "$details" | grep -Eq '(^|[[:space:]])flags=[^[:space:]]*\(adhoc,runtime\)' \
  || fail "ad-hoc and hardened runtime flags are required"
printf '%s\n' "$details" | grep -Fxq 'Signature=adhoc' \
  || fail "community release must use an ad-hoc signature"
printf '%s\n' "$details" | grep -Fxq 'TeamIdentifier=not set' \
  || fail "community release must not claim an Apple Team identity"
printf '%s\n' "$details" | grep -Eq '^Authority=' \
  && fail "certificate-backed signatures require the Developer ID release path"

printf '%s\n' "$details" \
  | grep -E '^(Signature=|TeamIdentifier=)|flags=[^[:space:]]*\(adhoc,runtime\)' >&2
