#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
validator="./Scripts/validate-community-signature.sh"
sha1="0DD76541008E2DD109E45A07942A0A2EBAC48D42"
identifier="com.openmouse.OpenMouse"
lower_sha1="$(printf '%s' "$sha1" | tr '[:upper:]' '[:lower:]')"
checks=0

expect_pass() {
  local description="$1" fixture="$2"
  checks=$((checks + 1))
  if printf '%s\n' "$fixture" | "$validator" "$sha1" "$identifier" >/dev/null 2>&1; then
    echo "   ✓ $description"
  else
    echo "   ✗ $description" >&2
    exit 1
  fi
}

expect_fail() {
  local description="$1" fixture="$2"
  checks=$((checks + 1))
  if printf '%s\n' "$fixture" | "$validator" "$sha1" "$identifier" >/dev/null 2>&1; then
    echo "   ✗ $description" >&2
    exit 1
  else
    echo "   ✓ $description"
  fi
}

valid=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+5 location=embedded\nSignature size=2246\nAuthority=Open Mouse Community Signing\nTeamIdentifier=not set\ndesignated => identifier "com.openmouse.OpenMouse" and certificate leaf = H"'"$lower_sha1"'"'
adhoc=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10002(adhoc,runtime) hashes=3+5 location=embedded\nSignature=adhoc\nTeamIdentifier=not set\ndesignated => cdhash H"1234"'
apple_development=$'Executable=/tmp/Open Mouse.app/Contents/MacOS/OpenMouse\nIdentifier=com.openmouse.OpenMouse\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+5 location=embedded\nAuthority=Apple Development: Example (ABCDE12345)\nTeamIdentifier=TEAM123456\ndesignated => identifier "com.openmouse.OpenMouse" and anchor apple generic'
developer_id="${apple_development/Apple Development/Developer ID Application}"
no_runtime="${valid/flags=0x10000(runtime)/flags=0x0(none)}"
claimed_team="${valid/TeamIdentifier=not set/TeamIdentifier=TEAM123456}"
wrong_authority="${valid/Open Mouse Community Signing/Some Other Certificate}"
wrong_certificate="${valid/$lower_sha1/1111111111111111111111111111111111111111}"
identifier_only="${valid/designated => identifier \"com.openmouse.OpenMouse\" and certificate leaf = H\"$lower_sha1\"/designated => identifier \"com.openmouse.OpenMouse\"}"
wrong_identifier="${valid/designated => identifier \"com.openmouse.OpenMouse\"/designated => identifier \"com.example.Impostor\"}"

expect_pass "固定自签名证书 + hardened runtime 可作为社区发布包" "$valid"
expect_fail "ad-hoc 签名不能再进入社区发布包" "$adhoc"
expect_fail "Apple Development 签名不能进入社区发布包" "$apple_development"
expect_fail "Developer ID 必须走正式发布流程" "$developer_id"
expect_fail "缺少 hardened runtime 时社区发布校验失败" "$no_runtime"
expect_fail "社区发布包不能声明 Apple Team" "$claimed_team"
expect_fail "证书名称不符时社区发布校验失败" "$wrong_authority"
expect_fail "Requirement 证书指纹不符时发布失败" "$wrong_certificate"
expect_fail "identifier-only Requirement 会转移 TCC 权限，必须拒绝" "$identifier_only"
expect_fail "Requirement Bundle ID 不符时发布失败" "$wrong_identifier"

expected_public_sha1="$(openssl x509 -inform der -in Resources/OpenMouseCommunitySigning.cer \
  -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')"
[ "$expected_public_sha1" = "$sha1" ]
checks=$((checks + 1))
echo "   ✓ 仓库公开证书指纹固定为 $sha1"

# The in-app update gate pins the same fingerprint in Swift. The certificate is not bundled, so
# the two copies cannot be compared at runtime -- if they ever drift, community builds silently
# stop offering automatic installation. Checked here instead.
gate_source="Sources/OpenMouseUpdateSupport/UpdateCodeSignature.swift"
grep -q "communitySigningCertificateSHA1 = \"$sha1\"" "$gate_source"
checks=$((checks + 1))
echo "   ✓ 应用内更新门槛钉住同一指纹 $sha1"

# Fingerprint, not common name: a self-signed subject is not a credential.
grep -q 'leafSHA1.caseInsensitiveCompare(communitySigningCertificateSHA1)' "$gate_source"
! grep -q 'commonName == "Open Mouse Community Signing"' "$gate_source"
checks=$((checks + 1))
echo "   ✓ 社区身份按证书指纹判定而不是按证书名称"

grep -q 'COMMUNITY_DISTRIBUTION=1 ./Scripts/bundle.sh' Makefile
grep -q 'sign-community-app.sh' Scripts/bundle.sh
grep -q 'smoke-testing signed release executables' Scripts/bundle.sh
checks=$((checks + 3))
echo "   ✓ make dist-community 强制启用社区发布模式"
echo "   ✓ bundle.sh 使用固定社区签名脚本"
echo "   ✓ bundle.sh 会实际启动发布二进制做冒烟检查"
echo "✓ $checks 项社区发布签名检查全部通过"
