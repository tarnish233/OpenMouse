#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
validator="./Scripts/validate-distribution-signature.sh"
checks=0

expect_pass() {
  local description="$1" fixture="$2"
  checks=$((checks + 1))
  if printf '%s\n' "$fixture" | "$validator" >/dev/null 2>&1; then
    echo "   ✓ $description"
  else
    echo "   ✗ $description" >&2
    exit 1
  fi
}

expect_fail() {
  local description="$1" fixture="$2"
  checks=$((checks + 1))
  if printf '%s\n' "$fixture" | "$validator" >/dev/null 2>&1; then
    echo "   ✗ $description" >&2
    exit 1
  else
    echo "   ✓ $description"
  fi
}

valid=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+5 location=embedded\nAuthority=Developer ID Application: Example (TEAM123)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=TEAM123\nTimestamp=Aug 31, 2026 at 12:00:00'
apple_development="${valid/Developer ID Application/Apple Development}"
no_timestamp="$(printf '%s\n' "$valid" | grep -v '^Timestamp=')"
no_runtime="${valid/flags=0x10000(runtime)/flags=0x0(none)}"

expect_pass "Developer ID + hardened runtime + secure timestamp 可发布" "$valid"
expect_fail "Apple Development 签名不能进入发布包" "$apple_development"
expect_fail "缺少安全时间戳时发布校验失败" "$no_timestamp"
expect_fail "缺少 hardened runtime 时发布校验失败" "$no_runtime"

grep -q 'DISTRIBUTION=1 ./Scripts/bundle.sh' Makefile
grep -q 'validate-distribution-signature.sh' Scripts/bundle.sh
checks=$((checks + 2))
echo "   ✓ make dist 强制启用发布签名模式"
echo "   ✓ bundle.sh 在打包前调用发布签名校验"
echo "✓ $checks 项发布签名检查全部通过"
