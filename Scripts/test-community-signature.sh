#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
validator="./Scripts/validate-community-signature.sh"
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

valid=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10002(adhoc,runtime) hashes=3+5 location=embedded\nSignature=adhoc\nTeamIdentifier=not set'
apple_development=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+5 location=embedded\nAuthority=Apple Development: Example (ABCDE12345)\nTeamIdentifier=TEAM123456'
developer_id="${apple_development/Apple Development/Developer ID Application}"
no_runtime="${valid/flags=0x10002(adhoc,runtime)/flags=0x2(adhoc)}"
claimed_team="${valid/TeamIdentifier=not set/TeamIdentifier=TEAM123456}"

expect_pass "ad-hoc + hardened runtime 可作为未公证社区发布包" "$valid"
expect_fail "Apple Development 签名不能进入社区发布包" "$apple_development"
expect_fail "Developer ID 必须走正式发布流程" "$developer_id"
expect_fail "缺少 hardened runtime 时社区发布校验失败" "$no_runtime"
expect_fail "社区发布包不能声明 Apple Team" "$claimed_team"

grep -q 'COMMUNITY_DISTRIBUTION=1 ./Scripts/bundle.sh' Makefile
grep -q 'validate-community-signature.sh' Scripts/bundle.sh
grep -q 'smoke-testing signed release executables' Scripts/bundle.sh
checks=$((checks + 3))
echo "   ✓ make dist-community 强制启用社区发布模式"
echo "   ✓ bundle.sh 在打包前校验社区签名"
echo "   ✓ bundle.sh 会实际启动发布二进制做冒烟检查"
echo "✓ $checks 项社区发布签名检查全部通过"
