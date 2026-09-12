#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
THIRD_PARTY_DIR="$PROJECT_DIR/ThirdParty/WebRTCNoiseSuppression"
LIBRARY="$PROJECT_DIR/Vendor/WebRTCNoiseSuppression.xcframework/macos-arm64/libWebRTCNoiseSuppression.a"
DEPLOYMENT_TARGET=14.2
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/audio-level-bar-vendor-smoke.XXXXXX")

cleanup() {
    case "$WORK_DIR" in
        "${TMPDIR:-/tmp}"/audio-level-bar-vendor-smoke.*) rm -rf "$WORK_DIR" ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" xcrun --sdk macosx clang \
    -std=c11 \
    -arch arm64 \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -I"$THIRD_PARTY_DIR/include" \
    -c "$THIRD_PARTY_DIR/Tests/smoke.c" \
    -o "$WORK_DIR/smoke.o"

MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" xcrun --sdk macosx clang++ \
    -arch arm64 \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    "$WORK_DIR/smoke.o" \
    "$LIBRARY" \
    -framework CoreFoundation \
    -framework Foundation \
    -o "$WORK_DIR/smoke"

"$WORK_DIR/smoke"
