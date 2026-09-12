#!/bin/sh

set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_dir=$(CDPATH= cd "$script_dir/.." && pwd)
third_party_dir="$repo_dir/ThirdParty/WebRTCNoiseSuppression"
output_dir="$repo_dir/Vendor/WebRTCNoiseSuppression.xcframework"

version=2.1
deployment_target=14.2
archive_name="webrtc-audio-processing-$version.tar.xz"
archive_url="https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/$archive_name"
archive_sha256=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
abseil_source_sha256=f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
abseil_patch_sha256=12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b

for command_name in ar awk curl grep libtool meson ninja shasum tar xcodebuild xcrun; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 1
    fi
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/audio-level-bar-webrtc.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

archive_path="$work_dir/$archive_name"
if [ -n "${ALB_WEBRTC_ARCHIVE:-}" ]; then
    cp "$ALB_WEBRTC_ARCHIVE" "$archive_path"
else
    curl --fail --location --show-error --output "$archive_path" "$archive_url"
fi

actual_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
if [ "$actual_sha256" != "$archive_sha256" ]; then
    echo "Unexpected $archive_name SHA-256: $actual_sha256" >&2
    exit 1
fi

tar -xf "$archive_path" -C "$work_dir"
source_dir="$work_dir/webrtc-audio-processing-$version"
wrap_file="$source_dir/subprojects/abseil-cpp.wrap"
if ! grep -F "source_hash = $abseil_source_sha256" "$wrap_file" >/dev/null ||
   ! grep -F "patch_hash = $abseil_patch_sha256" "$wrap_file" >/dev/null; then
    echo "The pinned Abseil hashes were not present in abseil-cpp.wrap" >&2
    exit 1
fi
if [ -n "${ALB_MESON_PACKAGE_CACHE:-}" ]; then
    mkdir -p "$source_dir/subprojects/packagecache"
    cp "$ALB_MESON_PACKAGE_CACHE"/* "$source_dir/subprojects/packagecache/"
fi

build_dir="$work_dir/build"
MACOSX_DEPLOYMENT_TARGET="$deployment_target" meson setup \
    "$build_dir" \
    "$source_dir" \
    --buildtype=release \
    --default-library=static \
    --wrap-mode=forcefallback \
    -Dneon=enabled
MACOSX_DEPLOYMENT_TARGET="$deployment_target" meson compile -C "$build_dir"

wrapper_object="$work_dir/WebRTCNoiseSuppression.o"
MACOSX_DEPLOYMENT_TARGET="$deployment_target" xcrun --sdk macosx clang++ \
    -std=c++17 \
    -O3 \
    -DNDEBUG \
    -DWEBRTC_LIBRARY_IMPL \
    -DWEBRTC_ENABLE_SYMBOL_EXPORT \
    -DWEBRTC_MAC \
    -DWEBRTC_POSIX \
    -DWEBRTC_ARCH_ARM64 \
    -DWEBRTC_HAS_NEON \
    -D_WINSOCKAPI_ \
    -arch arm64 \
    -mmacosx-version-min="$deployment_target" \
    -I"$third_party_dir/include" \
    -I"$source_dir/webrtc" \
    -I"$source_dir/subprojects/abseil-cpp-20240722.0" \
    -c "$third_party_dir/src/WebRTCNoiseSuppression.cpp" \
    -o "$wrapper_object"

combined_library="$work_dir/libWebRTCNoiseSuppression.a"
# Meson's top-level static APM archive already contains every transitive WebRTC
# and Abseil object. Adding its intermediate archives again would duplicate
# hundreds of members in the XCFramework.
for required_member in src_pffft.c.o src_rnn_vad_weights.cc.o absl_base_log_severity.cc.o; do
    if ! ar -t "$build_dir/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a" | \
        grep -F "$required_member" >/dev/null; then
        echo "The static APM archive did not contain $required_member" >&2
        exit 1
    fi
done
libtool -static -o "$combined_library" \
    "$wrapper_object" \
    "$build_dir"/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a

find "$build_dir" -type f -name '*.o' -print | while IFS= read -r object; do
    if ! xcrun vtool -show-build "$object" | grep -F "minos $deployment_target" >/dev/null; then
        echo "Unexpected deployment target in $object" >&2
        xcrun vtool -show-build "$object" >&2 || true
        exit 1
    fi
done
if ! xcrun vtool -show-build "$wrapper_object" | grep -F "minos $deployment_target" >/dev/null; then
    echo "Unexpected deployment target in the C bridge" >&2
    xcrun vtool -show-build "$wrapper_object" >&2 || true
    exit 1
fi

headers_dir="$work_dir/Headers"
mkdir -p "$headers_dir"
cp "$third_party_dir/include/WebRTCNoiseSuppression.h" "$headers_dir/"
cp "$third_party_dir/include/module.modulemap" "$headers_dir/"

temporary_xcframework="$work_dir/WebRTCNoiseSuppression.xcframework"
xcodebuild -create-xcframework \
    -library "$combined_library" \
    -headers "$headers_dir" \
    -output "$temporary_xcframework"

mkdir -p "$repo_dir/Vendor"
rm -rf "$output_dir"
cp -R "$temporary_xcframework" "$output_dir"

smoke_object="$work_dir/smoke.o"
smoke_binary="$work_dir/smoke"
MACOSX_DEPLOYMENT_TARGET="$deployment_target" xcrun --sdk macosx clang \
    -std=c11 \
    -arch arm64 \
    -mmacosx-version-min="$deployment_target" \
    -I"$third_party_dir/include" \
    -c "$third_party_dir/Tests/smoke.c" \
    -o "$smoke_object"
MACOSX_DEPLOYMENT_TARGET="$deployment_target" xcrun --sdk macosx clang++ \
    -arch arm64 \
    -mmacosx-version-min="$deployment_target" \
    "$smoke_object" \
    "$output_dir/macos-arm64/libWebRTCNoiseSuppression.a" \
    -framework CoreFoundation \
    -framework Foundation \
    -o "$smoke_binary"
"$smoke_binary"

echo "Representative bridge deployment target:"
xcrun vtool -show-build "$wrapper_object"
echo "Built $output_dir"
