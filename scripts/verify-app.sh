#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
APP_BUNDLE=${1:-"$PROJECT_DIR/dist/Audio Level Bar.app"}
EXPECTED_IDENTIFIER=io.github.yuhkis.audio-level-bar
SOURCE_INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AudioLevelBar"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
SOURCE_LICENSE="$PROJECT_DIR/LICENSE"
BUNDLE_LICENSE="$APP_BUNDLE/Contents/Resources/LICENSE"
SOURCE_LICENSES="$PROJECT_DIR/ThirdParty/WebRTCNoiseSuppression/LICENSES"
BUNDLE_LICENSES="$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/WebRTCNoiseSuppression"
SOURCE_RESOURCES="$PROJECT_DIR/Resources"
BUNDLE_RESOURCES="$APP_BUNDLE/Contents/Resources"
EXPECTED_DEVELOPMENT_REGION=en
EXPECTED_LOCALIZATIONS="en ja"
EXPECTED_STRINGS_TABLES="Localizable.strings InfoPlist.strings"
EXPECTED_LICENSES="Abseil.LICENSE FFT.LICENSE Ooura.LICENSE PFFFT.LICENSE RNNoise.COPYING SPLSqrtFloor.LICENSE WebRTC.LICENSE WebRTC.PATENTS webrtc-audio-processing.COPYING"

fail() {
    echo "Verification failed: $*" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || fail "missing Info.plist key $1"
}

source_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$SOURCE_INFO_PLIST" 2>/dev/null ||
        fail "missing source Info.plist key $1"
}

bundle_fingerprint() {
    (
        cd "$APP_BUNDLE"
        find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            hash=$(shasum -a 256 "$file" | awk '{print $1}')
            printf '%s %s\n' "$hash" "$file"
        done
    ) | shasum -a 256 | awk '{print $1}'
}

[ -f "$SOURCE_INFO_PLIST" ] || fail "source Info.plist is missing"
EXPECTED_VERSION=$(source_plist_value CFBundleShortVersionString)
EXPECTED_BUILD=$(source_plist_value CFBundleVersion)
EXPECTED_MINIMUM_SYSTEM_VERSION=$(source_plist_value LSMinimumSystemVersion)

[ ! -L "$APP_BUNDLE" ] || fail "the app bundle is a symbolic link"
[ -d "$APP_BUNDLE" ] || fail "app bundle not found at $APP_BUNDLE"
if find "$APP_BUNDLE" -type l -print -quit | grep -q .; then
    fail "symbolic links are not allowed inside the app bundle"
fi
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing"
[ ! -L "$EXECUTABLE" ] || fail "the executable is a symbolic link"
[ -x "$EXECUTABLE" ] || fail "the executable is missing or not executable"

identifier=$(plist_value CFBundleIdentifier)
development_region=$(plist_value CFBundleDevelopmentRegion)
version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
bundle_minimum_system_version=$(plist_value LSMinimumSystemVersion)
git_commit=$(plist_value AudioLevelBarGitCommit)
git_state=$(plist_value AudioLevelBarGitState)
source_fingerprint=$(plist_value AudioLevelBarSourceFingerprint)
provenance_timestamp=$(plist_value AudioLevelBarProvenanceTimestamp)

[ "$identifier" = "$EXPECTED_IDENTIFIER" ] || fail "Bundle ID is $identifier, expected $EXPECTED_IDENTIFIER"
[ "$development_region" = "$EXPECTED_DEVELOPMENT_REGION" ] ||
    fail "development region is $development_region, expected $EXPECTED_DEVELOPMENT_REGION"
[ "$version" = "$EXPECTED_VERSION" ] || fail "version is $version, expected $EXPECTED_VERSION"
[ "$build" = "$EXPECTED_BUILD" ] || fail "build is $build, expected $EXPECTED_BUILD"
[ "$bundle_minimum_system_version" = "$EXPECTED_MINIMUM_SYSTEM_VERSION" ] ||
    fail "bundle minimum system version is $bundle_minimum_system_version, expected $EXPECTED_MINIMUM_SYSTEM_VERSION"
case "$git_commit" in
    source-archive) ;;
    *) printf '%s\n' "$git_commit" | grep -Eq '^[0-9a-f]{40}$' || fail "Git commit is not a full SHA" ;;
esac
case "$git_state" in clean|dirty|source-archive) ;; *) fail "Git state is invalid" ;; esac
printf '%s\n' "$source_fingerprint" | grep -Eq '^[0-9a-f]{64}$' || fail "source fingerprint is not SHA-256"
case "$provenance_timestamp" in
    source-archive) ;;
    *) printf '%s\n' "$provenance_timestamp" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || fail "provenance timestamp is not UTC ISO 8601" ;;
esac
if [ "$git_state" = source-archive ]; then
    [ "$git_commit" = source-archive ] || fail "source archive has a Git commit"
    [ "$provenance_timestamp" = source-archive ] || fail "source archive has a Git timestamp"
else
    [ "$git_commit" != source-archive ] || fail "Git checkout is missing its commit"
    [ "$provenance_timestamp" != source-archive ] || fail "Git checkout is missing its timestamp"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 || fail "code signature is invalid"
architectures=$(lipo -archs "$EXECUTABLE")
printf '%s\n' "$architectures" | tr ' ' '\n' | grep -qx arm64 || fail "arm64 executable slice is missing"
minimum_system_version=$(xcrun vtool -show-build "$EXECUTABLE" | awk '$1 == "minos" { print $2; exit }')
[ "$minimum_system_version" = "$bundle_minimum_system_version" ] ||
    fail "executable minimum system version is $minimum_system_version, bundle declares $bundle_minimum_system_version"

[ -f "$SOURCE_LICENSE" ] || fail "the project LICENSE is missing from the source tree"
[ -f "$BUNDLE_LICENSE" ] || fail "the project LICENSE is missing from the bundle"
[ -s "$BUNDLE_LICENSE" ] || fail "the bundled project LICENSE is empty"
cmp -s "$SOURCE_LICENSE" "$BUNDLE_LICENSE" || fail "the bundled project LICENSE differs from the source LICENSE"

[ -d "$BUNDLE_LICENSES" ] || fail "third-party licenses are missing"
for license_name in $EXPECTED_LICENSES; do
    bundled_license="$BUNDLE_LICENSES/$license_name"
    [ -f "$bundled_license" ] || fail "missing license $license_name"
    [ -s "$bundled_license" ] || fail "empty license $license_name"
    if [ -f "$SOURCE_LICENSES/$license_name" ]; then
        cmp -s "$SOURCE_LICENSES/$license_name" "$bundled_license" || fail "license differs from source: $license_name"
    fi
done

for localization in $EXPECTED_LOCALIZATIONS; do
    source_lproj="$SOURCE_RESOURCES/$localization.lproj"
    bundle_lproj="$BUNDLE_RESOURCES/$localization.lproj"
    [ -d "$source_lproj" ] || fail "source localization is missing: $localization.lproj"
    [ -d "$bundle_lproj" ] || fail "bundled localization is missing: $localization.lproj"
    for table in $EXPECTED_STRINGS_TABLES; do
        [ -f "$source_lproj/$table" ] || fail "missing source $localization.lproj/$table"
        [ -f "$bundle_lproj/$table" ] || fail "missing bundled $localization.lproj/$table"
        [ -s "$bundle_lproj/$table" ] || fail "empty bundled $localization.lproj/$table"
        cmp -s "$source_lproj/$table" "$bundle_lproj/$table" ||
            fail "bundled $localization.lproj/$table differs from source"
        plutil -lint "$bundle_lproj/$table" >/dev/null ||
            fail "bundled $localization.lproj/$table is not a valid strings file"
    done
done

build_info=$("$EXECUTABLE" --build-info) || fail "--build-info did not complete"
printf '%s\n' "$build_info" | grep -Fx "Audio Level Bar $version (build $build)" >/dev/null || fail "--build-info version/build mismatch"
printf '%s\n' "$build_info" | grep -Fx "Bundle ID: $identifier" >/dev/null || fail "--build-info Bundle ID mismatch"
printf '%s\n' "$build_info" | grep -Fx "Git commit: $git_commit" >/dev/null || fail "--build-info Git commit mismatch"
printf '%s\n' "$build_info" | grep -Fx "Git state: $git_state" >/dev/null || fail "--build-info Git state mismatch"
printf '%s\n' "$build_info" | grep -Fx "Source fingerprint: $source_fingerprint" >/dev/null || fail "--build-info source fingerprint mismatch"
printf '%s\n' "$build_info" | grep -Fx "Provenance timestamp: $provenance_timestamp" >/dev/null || fail "--build-info timestamp mismatch"

signature_info=$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)
cdhash=$(printf '%s\n' "$signature_info" | sed -n 's/^CDHash=//p' | head -n 1)
[ -n "$cdhash" ] || fail "CDHash could not be read"

# The signature is ad hoc by default, or a certificate named by CODESIGN_IDENTITY
# (the same contract as make app and wkr-macos). A certificate signature must
# carry the hardened runtime and the audio-input entitlement, because the
# hardened runtime denies microphone input without it.
requested_identity=${CODESIGN_IDENTITY:-}
[ "$requested_identity" != '-' ] || requested_identity=
if printf '%s\n' "$signature_info" | grep -Fx 'Signature=adhoc' >/dev/null; then
    [ -z "$requested_identity" ] ||
        fail "signature is ad hoc, but CODESIGN_IDENTITY requested $requested_identity"
    signature_summary="ad hoc"
else
    printf '%s\n' "$signature_info" | grep -E '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' >/dev/null ||
        fail "certificate signature lacks the hardened runtime"
    entitlements=$(codesign -d --entitlements - --xml "$APP_BUNDLE" 2>/dev/null | tr -d ' \t\n') ||
        fail "entitlements could not be read"
    case "$entitlements" in
        *'<key>com.apple.security.device.audio-input</key><true/>'*) ;;
        *) fail "certificate signature lacks the com.apple.security.device.audio-input entitlement" ;;
    esac
    authority=$(printf '%s\n' "$signature_info" | sed -n 's/^Authority=//p' | head -n 1)
    [ -n "$authority" ] || fail "signing authority could not be read"
    if [ -n "$requested_identity" ]; then
        signed_by_requested=false
        if [ "$authority" = "$requested_identity" ]; then
            signed_by_requested=true
        elif printf '%s\n' "$requested_identity" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
            certificate_dir=$(mktemp -d "${TMPDIR:-/tmp}/audio-level-bar-certificates.XXXXXX")
            codesign -d --extract-certificates="$certificate_dir/certificate" "$APP_BUNDLE" 2>/dev/null ||
                fail "signing certificate could not be extracted"
            leaf_hash=$(openssl x509 -inform DER -in "$certificate_dir/certificate0" -noout -fingerprint -sha1 2>/dev/null |
                sed 's/^.*=//; s/://g' | tr '[:lower:]' '[:upper:]')
            rm -rf "$certificate_dir"
            [ "$leaf_hash" = "$(printf '%s' "$requested_identity" | tr '[:lower:]' '[:upper:]')" ] &&
                signed_by_requested=true
        fi
        [ "$signed_by_requested" = true ] ||
            fail "signed by $authority, but CODESIGN_IDENTITY requested $requested_identity"
    fi
    signature_summary="certificate ($authority), hardened runtime, audio-input entitlement"
fi
content_fingerprint=$(bundle_fingerprint)

printf '%s\n' \
    "Verified: $APP_BUNDLE" \
    "Version/build: $version ($build)" \
    "Bundle ID: $identifier" \
    "Localizations: $EXPECTED_LOCALIZATIONS" \
    "Git commit/state: $git_commit ($git_state)" \
    "Source fingerprint: $source_fingerprint" \
    "Provenance timestamp: $provenance_timestamp" \
    "Architectures: $architectures" \
    "Minimum system version: $minimum_system_version" \
    "Signature: $signature_summary" \
    "CDHash: $cdhash" \
    "Bundle content fingerprint: $content_fingerprint"
