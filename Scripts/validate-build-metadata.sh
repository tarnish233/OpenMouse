#!/usr/bin/env bash
# Validate every macOS slice in `xcrun vtool -show-build` output. The SDK controls
# AppKit/SwiftUI linked-on behavior; it is NOT the minimum supported OS version.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <selected-sdk-version> <minimum-macos-version>" >&2; exit 64; }

awk -v expected_sdk="$1" -v expected_min="$2" '
function valid_version(value, parts, count, i) {
    count = split(value, parts, ".")
    if (count < 1 || count > 3) return 0
    for (i = 1; i <= count; i++) if (parts[i] !~ /^[0-9]+$/) return 0
    return 1
}
function same_version(left, right, a, b, i) {
    if (!valid_version(left) || !valid_version(right)) return 0
    split(left, a, "."); split(right, b, ".")
    for (i = 1; i <= 3; i++) if (a[i] + 0 != b[i] + 0) return 0
    return 1
}
function fail(message) {
    print "error: " message > "/dev/stderr"
    failed = 1
}
function finish_slice() {
    if (!in_build) return
    slices++
    if (platform_count != 1 || platform != "MACOS")
        fail("build slice " slices " must identify the MACOS platform")
    if (min_count != 1 || !same_version(minos, expected_min))
        fail("build slice " slices " minimum macOS " minos " != expected " expected_min)
    if (sdk_count != 1 || !same_version(sdk, expected_sdk))
        fail("build slice " slices " SDK " sdk " != selected SDK " expected_sdk)
    in_build = 0
}
BEGIN {
    if (!valid_version(expected_sdk) || !valid_version(expected_min)) {
        fail("SDK and minimum macOS versions must be numeric version strings")
        invalid_arguments = 1
        exit 1
    }
}
/\(architecture [^)]+\):$/ { architectures++ }
$1 == "cmd" {
    finish_slice()
    if ($2 == "LC_BUILD_VERSION") {
        in_build = 1
        platform = minos = sdk = ""
        platform_count = min_count = sdk_count = 0
    } else if ($2 ~ /^LC_VERSION_MIN_/) {
        # A second legacy slice must not hide behind a valid modern slice.
        fail("legacy version load command found; expected LC_BUILD_VERSION")
    }
    next
}
in_build && $1 == "platform" { platform = $2; platform_count++; next }
in_build && $1 == "minos" { minos = $2; min_count++; next }
in_build && $1 == "sdk" { sdk = $2; sdk_count++; next }
END {
    if (!invalid_arguments) {
        finish_slice()
        if (!slices) fail("no LC_BUILD_VERSION metadata found")
        if (architectures && architectures != slices)
            fail("not every architecture has exactly one LC_BUILD_VERSION")
    }
    if (failed) exit 1
    print "✓ macOS build metadata: SDK " expected_sdk ", minimum " expected_min " (" slices " slice(s))"
}'
