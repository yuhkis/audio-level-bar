#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
THIRD_PARTY_DIR="$PROJECT_DIR/ThirdParty/WebRTCNoiseSuppression"
XCFRAMEWORK="$PROJECT_DIR/Vendor/WebRTCNoiseSuppression.xcframework"
LIBRARY="$XCFRAMEWORK/macos-arm64/libWebRTCNoiseSuppression.a"
EXPECTED_SHA256=bed0622218382fa663d0315cc6e1abe110a7753e10754b0bef77b6d1fcb47b43

fail() {
    echo "Vendor verification failed: $*" >&2
    exit 1
}

[ -f "$XCFRAMEWORK/Info.plist" ] || fail "XCFramework Info.plist is missing"
[ -f "$LIBRARY" ] || fail "static library is missing"
plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null || fail "XCFramework Info.plist is invalid"

actual_sha256=$(shasum -a 256 "$LIBRARY" | awk '{print $1}')
[ "$actual_sha256" = "$EXPECTED_SHA256" ] ||
    fail "static library SHA-256 is $actual_sha256, expected $EXPECTED_SHA256"

architectures=$(lipo -archs "$LIBRARY")
[ "$architectures" = arm64 ] || fail "static library architectures are $architectures, expected arm64"

cmp -s \
    "$THIRD_PARTY_DIR/include/WebRTCNoiseSuppression.h" \
    "$XCFRAMEWORK/macos-arm64/Headers/WebRTCNoiseSuppression.h" ||
    fail "vendored header differs from ThirdParty source"
cmp -s \
    "$THIRD_PARTY_DIR/include/module.modulemap" \
    "$XCFRAMEWORK/macos-arm64/Headers/module.modulemap" ||
    fail "vendored module map differs from ThirdParty source"

echo "Verified vendored WebRTC noise suppression: $actual_sha256 ($architectures)"
