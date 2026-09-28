#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VALIDATOR="$ROOT/Scripts/validate-build-metadata.sh"
checks=0
valid='Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 14.0
      sdk 27.0
   ntools 1'
expect_pass() {
    local description="$1" input="$2" sdk="${3-27.0}" minimum="${4-14.0}"
    if ! printf '%s\n' "$input" | "$VALIDATOR" "$sdk" "$minimum" >/dev/null 2>&1; then
        echo "FAIL: $description" >&2; exit 1
    fi
    checks=$((checks + 1)); echo "   ✓ $description"
}
expect_fail() {
    local description="$1" input="$2" sdk="${3-27.0}" minimum="${4-14.0}"
    if printf '%s\n' "$input" | "$VALIDATOR" "$sdk" "$minimum" >/dev/null 2>&1; then
        echo "FAIL: $description" >&2; exit 1
    fi
    checks=$((checks + 1)); echo "   ✓ $description"
}
expect_pass 'SDK 27 与最低 macOS 14 保持独立' "$valid"
expect_pass '旧工具链按实际选定 SDK 26.5 校验，不硬编码 27' "${valid/27.0/26.5}" 26.5
expect_pass '实际使用 SDK 14 时允许 SDK 与最低版本相等' "${valid/27.0/14.0}" 14.0
expect_pass '等价版本号允许省略末尾零' "$valid" 27 14.0.0
expect_pass '构建输出的三个版本分量也可归一化比较' "${valid/27.0/27.0.0}"
expect_fail '拒绝 v0.7.5 的 SDK 回退为最低系统版本回归' "${valid/27.0/14.0}"
expect_fail '拒绝将最低支持系统意外提高到 27' "${valid/minos 14.0/minos 27.0}"
expect_fail '拒绝最低系统低于应用声明的版本' "${valid/minos 14.0/minos 13.0}"
expect_fail '拒绝旧缓存产物的 SDK 26.5 冒充当前 SDK 27' "${valid/27.0/26.5}"
expect_fail '没有输出时不能算校验通过' ''
expect_fail '缺少 SDK 字段时失败' "${valid/sdk 27.0/}"
expect_fail '缺少最低版本字段时失败' "${valid/minos 14.0/}"
expect_fail '非 macOS 平台不能打进 macOS 发布包' "${valid/MACOS/IOS}"
expect_fail '拒绝损坏的 SDK 版本字段' "${valid/27.0/27.beta}"
expect_fail '拒绝重复 SDK 字段' "$valid
sdk 27.0"
expect_fail '拒绝旧式版本命令掩盖缺失的构建 SDK' 'cmd LC_VERSION_MIN_MACOSX
version 14.0
sdk 27.0'
expect_pass '通用二进制的所有架构均符合要求时通过' "$valid
$valid"
expect_fail '通用二进制任一架构 SDK 错误就失败' "$valid
${valid/27.0/14.0}"
expect_fail '通用二进制末尾架构字段不完整就失败' "$valid
cmd LC_BUILD_VERSION
platform MACOS"
expect_fail '通用二进制不能跳过没有构建信息的架构' "app (architecture arm64):
$valid
app (architecture x86_64):"
expect_fail '通用二进制不能混入未校验的旧式版本命令' "$valid
cmd LC_VERSION_MIN_MACOSX
version 14.0
sdk 14.0"
expect_fail '拒绝非数字的预期 SDK 参数' "$valid" invalid
expect_fail '拒绝空的预期最低版本参数' "$valid" 27.0 ''

# Exercise the actual bundler with fake compiler/vtool results. A bad main OR helper
# must fail before touching an existing bundle; no compiler, keychain, or signing is used.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/OpenMouseBuildMetadata.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools" "$tmp/products" "$tmp/output/Open Mouse.app"
touch "$tmp/products/OpenMouse" "$tmp/products/OpenMouseUpdater" "$tmp/output/Open Mouse.app/keep-existing-bundle"
cat > "$tmp/tools/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = '--sdk' ]; then
    case "$3" in
        --show-sdk-path) echo '/FakeSDK/MacOSX27.0.sdk' ;;
        --show-sdk-version) echo '27.0' ;;
        *) exit 91 ;;
    esac
elif [ "$1" = 'swift' ]; then
    shift
    printf '%s\n' "$@" >> "$PROBE_ARGUMENTS"
    if [ "${!#}" = '--show-bin-path' ]; then echo "$PROBE_PRODUCTS"; fi
elif [ "$1" = 'vtool' ] && [ "$2" = '-show-build' ]; then
    sdk=27.0
    if [ "$(basename "$3")" = "$PROBE_BAD_BINARY" ]; then sdk=14.0; fi
    printf 'cmd LC_BUILD_VERSION\nplatform MACOS\nminos 14.0\nsdk %s\n' "$sdk"
else
    exit 92
fi
STUB
chmod +x "$tmp/tools/xcrun"
for binary in OpenMouse OpenMouseUpdater; do
    if PATH="$tmp/tools:$PATH" OUT_DIR="$tmp/output" CONFIG=release DEBUG_VARIANT=0 \
       DISTRIBUTION=0 COMMUNITY_DISTRIBUTION=0 \
       PROBE_PRODUCTS="$tmp/products" PROBE_BAD_BINARY="$binary" PROBE_ARGUMENTS="$tmp/arguments" \
       "$ROOT/Scripts/bundle.sh" >"$tmp/bundle.log" 2>&1; then
        echo "FAIL: bundler accepted incorrect SDK in $binary" >&2; exit 1
    fi
    grep -q 'SDK 14.0 != selected SDK 27.0' "$tmp/bundle.log"
    test -f "$tmp/output/Open Mouse.app/keep-existing-bundle"
    checks=$((checks + 1)); echo "   ✓ $binary 的 SDK 错误会在覆盖现有应用前阻止打包"
done
grep -q -x -- '--sdk' "$tmp/arguments"
grep -q -x -- '/FakeSDK/MacOSX27.0.sdk' "$tmp/arguments"
grep -q -x -- '-platform_version' "$tmp/arguments"
grep -q -x -- 'macos' "$tmp/arguments"
grep -q -x -- '14.0' "$tmp/arguments"
grep -q -x -- '27.0' "$tmp/arguments"
checks=$((checks + 1)); echo '   ✓ 编译与链接显式使用选定 SDK，同时保持最低系统 14'
echo "✓ $checks 项构建元数据检查全部通过"
