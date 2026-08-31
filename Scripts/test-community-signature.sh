#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
validator="./Scripts/validate-community-signature.sh"
checks=0

expect_pass() {
  local description="$1" fixture="$2"
  checks=$((checks + 1))
  if printf '%s\n' "$fixture" | "$validator" "${team:-TEAM123456}" >/dev/null 2>&1; then
    echo "   ✓ $description"
  else
    echo "   ✗ $description" >&2
    exit 1
  fi
}

expect_fail() {
  local description="$1" fixture="$2"
  checks=$((checks + 1))
  if printf '%s\n' "$fixture" | "$validator" "${team:-TEAM123456}" >/dev/null 2>&1; then
    echo "   ✗ $description" >&2
    exit 1
  else
    echo "   ✓ $description"
  fi
}

team='TEAM123456'
valid=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+5 location=embedded\nAuthority=Apple Development: Example (ABCDE12345)\nTeamIdentifier=TEAM123456'
wrong_authority="${valid/Apple Development: Example (ABCDE12345)/Apple Development: Someone Else (ZZZZZ99999)}"
ad_hoc=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+5 location=embedded\nSignature=adhoc\nTeamIdentifier=not set'
no_runtime="${valid/flags=0x10000(runtime)/flags=0x0(none)}"

checks=$((checks + 1))
if printf '%s\n' "$valid" | "$validator" "$team" >/dev/null 2>&1; then
  echo "   ✓ 固定 Apple Development 身份 + hardened runtime 可发布"
else
  echo "   ✗ 固定 Apple Development 身份 + hardened runtime 可发布" >&2
  exit 1
fi
checks=$((checks + 1))
if printf '%s\n' "$wrong_authority" | "$validator" "$team" >/dev/null 2>&1; then
  echo "   ✓ 同一 Apple Team 的续期证书仍可发布"
else
  echo "   ✗ 同一 Apple Team 的续期证书仍可发布" >&2
  exit 1
fi
expect_fail "ad-hoc 签名不能进入社区发布包" "$ad_hoc"
expect_fail "缺少 hardened runtime 时社区发布校验失败" "$no_runtime"
checks=$((checks + 1))
if printf '%s\n' "$valid" | "$validator" 'OTHERTEAM0' >/dev/null 2>&1; then
  echo "   ✗ 其他 Apple Team 不能进入社区发布包" >&2
  exit 1
else
  echo "   ✓ 其他 Apple Team 不能进入社区发布包"
fi

grep -q 'COMMUNITY_DISTRIBUTION=1 ./Scripts/bundle.sh' Makefile
grep -q 'validate-community-signature.sh' Scripts/bundle.sh
checks=$((checks + 2))
echo "   ✓ make dist-community 强制启用固定社区签名"
echo "   ✓ bundle.sh 在打包前校验社区签名"
echo "✓ $checks 项社区发布签名检查全部通过"
