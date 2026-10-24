#!/bin/sh
# Build the distributable form of Audio Level Bar: a stripped, signed, and
# optionally notarized app bundle, packaged as a disk image (default) or a ZIP
# archive, each beside its SHA-256, under dist/release/.
#
#   make release                            disk image
#   make release RELEASE_FLAGS=--zip        ZIP archive
#   make release RELEASE_FLAGS='--dmg --zip' both
#
# Environment:
#   CODESIGN_IDENTITY  The certificate to sign with. Anything handed to other
#                      people needs a "Developer ID Application" certificate;
#                      unset, the build is signed ad hoc and not distributable.
#   NOTARY_PROFILE     The keychain profile `xcrun notarytool store-credentials`
#                      created. Set, the app and the disk image are notarized
#                      and stapled; unset, nothing is notarized, and Gatekeeper
#                      on another Mac refuses to open the result.
#
# No certificate is ever picked from the keychain, and nothing is uploaded
# anywhere but to Apple's notary service, and only when NOTARY_PROFILE is set.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
BUILD_SCRIPT="$SCRIPT_DIR/build-app.sh"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-app.sh"
SCAN_SCRIPT="$SCRIPT_DIR/scan-private-content.sh"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_NAME="Audio Level Bar.app"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AudioLevelBar"
VOLUME_NAME="Audio Level Bar"
# A scratch directory of its own: the distribution flags differ from the
# development build's, and sharing one would rebuild everything each time the
# two alternate.
SCRATCH_DIR="${AUDIO_LEVEL_BAR_BUILD_DIR:-$PROJECT_DIR/.build}/distribution"
NOTARY_TIMEOUT=1h
# Written apart from its colon: the full certificate subject is a shape the
# repository's own scanner refuses, since it carries a real name and Team ID.
DEVELOPER_ID_APPLICATION='Developer ID Application'

usage() {
    cat <<'USAGE'
usage: scripts/release-app.sh [--dmg] [--zip] [--allow-dirty]

  --dmg          Package the app as "Audio Level Bar-<version>.dmg" (default)
  --zip          Package the app as "Audio Level Bar-<version>.zip"
  --allow-dirty  Build from a working tree with uncommitted changes. The
                 bundle records its state as dirty; do not distribute it.

CODESIGN_IDENTITY names the signing certificate and NOTARY_PROFILE the
notarytool keychain profile. Without them the result is signed ad hoc and not
notarized: enough to rehearse every step, not enough to hand to anyone.
USAGE
}

make_dmg=false
make_zip=false
allow_dirty=false
for argument; do
    case "$argument" in
        --dmg) make_dmg=true ;;
        --zip) make_zip=true ;;
        --allow-dirty) allow_dirty=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done
if [ "$make_dmg" = false ] && [ "$make_zip" = false ]; then
    make_dmg=true
fi

identity=${CODESIGN_IDENTITY:-}
[ "$identity" != '-' ] || identity=
notary_profile=${NOTARY_PROFILE:-}

WORK_DIR=
MOUNT_POINT=
COMPLETED=false
# Set once this run has emptied dist/release/. Before that, the directory
# still holds the previous run's output, which a refusal must leave alone.
RELEASE_DIR_OWNED=false
NOTARIZED_IDS=
STAPLED_APP=false

fail() {
    echo "Release refused: $*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
}

detach_image() {
    [ -n "$MOUNT_POINT" ] || return 0
    attempts=0
    while ! hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 10 ]; then
            hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1 || true
            break
        fi
        sleep 1
    done
    MOUNT_POINT=
}

cleanup() {
    detach_image
    if [ "$COMPLETED" = false ] && [ "$RELEASE_DIR_OWNED" = true ] && [ -d "$RELEASE_DIR" ]; then
        # A run that did not finish keeps the bundle for inspection, and no
        # file that looks like something to hand out.
        for artifact in "$RELEASE_DIR"/*.dmg "$RELEASE_DIR"/*.zip "$RELEASE_DIR"/*.sha256; do
            [ ! -e "$artifact" ] || rm -f "$artifact"
        done
        echo "No disk image, archive, or checksum was left in dist/release/." >&2
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        case "$WORK_DIR" in
            "$DIST_DIR"/.audio-level-bar-release.*) rm -rf "$WORK_DIR" || true ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || fail "missing Info.plist key $2"
}

bundle_fingerprint() {
    (
        cd "$1"
        find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            hash=$(shasum -a 256 "$file" | awk '{print $1}')
            printf '%s %s\n' "$hash" "$file"
        done
    ) | shasum -a 256 | awk '{print $1}'
}

is_mach_o() {
    case "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" in
        cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# The scanner reads stdin and reports a hit as a reason and line numbers,
# never as the matched text. NUL bytes are dropped first, as the pre-push hook
# does: the scanner's own `$(cat)` drops them anyway.
scan_stdin() {
    tr -d '\000' | "$SCAN_SCRIPT" "$1"
}

# The strict gate: every name in the bundle, and the contents of every file as
# the build produced them. A Mach-O file is scanned with its code signature
# removed, and the ticket stapler writes is left out, because both are written
# by codesign and Apple rather than by the build, and a Developer ID signature
# names its signer by design. report_signature scans those bytes on their own.
scan_bundle() {
    bundle=$1
    what=$2
    hits=0
    scanned=0
    (cd "$bundle" && find . -print | LC_ALL=C sort) >"$WORK_DIR/names"
    scan_stdin "$what: file names" <"$WORK_DIR/names" || hits=$((hits + 1))
    (cd "$bundle" && find . -type f -print | LC_ALL=C sort) >"$WORK_DIR/files"
    while IFS= read -r file; do
        if [ "$file" = ./Contents/CodeResources ] && [ "$STAPLED_APP" = true ]; then
            continue
        fi
        scanned=$((scanned + 1))
        if is_mach_o "$bundle/$file"; then
            unsigned="$WORK_DIR/unsigned"
            rm -f "$unsigned"
            cp "$bundle/$file" "$unsigned"
            codesign --remove-signature "$unsigned"
            scan_stdin "$what: ${file#./} without its code signature" <"$unsigned" || hits=$((hits + 1))
        else
            scan_stdin "$what: ${file#./}" <"$bundle/$file" || hits=$((hits + 1))
        fi
    done <"$WORK_DIR/files"
    printf 'Scanned the names and the contents of %s files in the %s: %s with a hit.\n' \
        "$scanned" "$what" "$hits"
    [ "$hits" -eq 0 ] || fail "private content in the $what (the BLOCKED lines above name the file and the reason); nothing was packaged"
}

# signature_bytes <mach-o>: the code signature of each architecture slice.
signature_bytes() {
    file=$1
    archs=$(lipo -archs "$file")
    for arch in $archs; do
        slice="$WORK_DIR/slice"
        rm -f "$slice"
        if [ "$(printf '%s\n' "$archs" | wc -w | tr -d ' ')" -gt 1 ]; then
            lipo -thin "$arch" -output "$slice" "$file"
        else
            cp "$file" "$slice"
        fi
        region=$(otool -l "$slice" |
            awk '/cmd LC_CODE_SIGNATURE/ { found = 1 } found && $1 == "dataoff" { offset = $2 } found && $1 == "datasize" { print offset, $2; exit }')
        [ -n "$region" ] || continue
        set -- $region
        tail -c "+$(($1 + 1))" "$slice" | head -c "$2"
    done
}

# Not a gate. A certificate signature carries the certificate chain, whose
# subject is the signer's name and Team ID, and that is what Developer ID
# distribution publishes. The scan says whether the signature names anything
# the pattern list holds, so that a signature made with the wrong certificate
# is seen before the result is handed out.
report_signature() {
    signature_data="$WORK_DIR/signature-data"
    : >"$signature_data"
    while IFS= read -r file; do
        if is_mach_o "$APP_BUNDLE/$file"; then
            signature_bytes "$APP_BUNDLE/$file" >>"$signature_data"
        fi
    done <"$WORK_DIR/files"
    if [ "$STAPLED_APP" = true ]; then
        cat "$APP_BUNDLE/Contents/CodeResources" >>"$signature_data"
    fi
    if scan_stdin "code signature" <"$signature_data" 2>"$WORK_DIR/signature.err"; then
        SIGNATURE_SCAN="names nothing the scanner looks for"
        echo "The code signature names nothing the scanner looks for."
    else
        sed 's/^/    /' "$WORK_DIR/signature.err"
        SIGNATURE_SCAN="names the signer (see the lines under the scan)"
        echo "The code signature names its signer, as every certificate signature does. Check with 'codesign -dv --verbose=4' that the certificate is the one issued to you before handing the result to anyone."
    fi
}

# notarize <path> <what>: submit, wait, and require Accepted.
notarize() {
    submission=$1
    what=$2
    result="$WORK_DIR/notary-$what.json"
    step "Submitting the $what for notarization (keychain profile: $notary_profile)"
    if ! xcrun notarytool submit "$submission" \
        --keychain-profile "$notary_profile" \
        --wait --timeout "$NOTARY_TIMEOUT" \
        --output-format json >"$result"; then
        [ ! -s "$result" ] || cat "$result"
        fail "notarytool submit did not complete for the $what"
    fi
    submission_id=$(plutil -extract id raw -o - -- "$result" 2>/dev/null || true)
    submission_status=$(plutil -extract status raw -o - -- "$result" 2>/dev/null || true)
    printf 'Submission %s: %s\n' "${submission_id:-?}" "${submission_status:-unknown}"
    if [ "$submission_status" != Accepted ]; then
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" || true
        fi
        fail "the notary service did not accept the $what (status: ${submission_status:-unknown})"
    fi
    NOTARIZED_IDS="$NOTARIZED_IDS $what=$submission_id"
}

staple() {
    xcrun stapler staple "$1"
    xcrun stapler validate "$1"
}

# gatekeeper <label> <spctl arguments...>: required to pass when notarized,
# shown for information otherwise.
gatekeeper() {
    label=$1
    shift
    if assessment=$(spctl --assess --verbose=4 "$@" 2>&1); then
        assessed=accepted
    else
        assessed=rejected
    fi
    printf '%s\n' "$assessment" | sed -n 's/^.*: //p; /^source=/p' | sed 's/^/    /'
    if [ -n "$notary_profile" ]; then
        [ "$assessed" = accepted ] || fail "Gatekeeper rejected the $label"
        printf '%s\n' "$assessment" | grep -q '^source=Notarized Developer ID' ||
            fail "Gatekeeper accepted the $label, but not as notarized Developer ID"
        printf 'Gatekeeper accepts the %s as notarized Developer ID.\n' "$label"
    else
        printf 'Gatekeeper on this Mac: %s (expected without notarization).\n' "$assessed"
    fi
}

# ---- Preconditions ---------------------------------------------------------

cd "$PROJECT_DIR"
for command_name in codesign ditto hdiutil lipo nm od otool plutil shasum spctl strip xcrun zipinfo; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
done
[ -x "$BUILD_SCRIPT" ] || fail "$BUILD_SCRIPT is missing or not executable"
[ -x "$VERIFY_SCRIPT" ] || fail "$VERIFY_SCRIPT is missing or not executable"
# Fail closed: the scanner is the gate between this build and other people.
[ -x "$SCAN_SCRIPT" ] || fail "$SCAN_SCRIPT is missing or not executable (run make setup-dev)"

if [ -n "$notary_profile" ] && [ -z "$identity" ]; then
    fail "NOTARY_PROFILE is set but CODESIGN_IDENTITY is not. Notarization needs a Developer ID Application certificate: name it in CODESIGN_IDENTITY, or unset NOTARY_PROFILE for a build that is not notarized."
fi

PROJECT_DIR_PHYSICAL=$(CDPATH= cd -- "$PROJECT_DIR" && pwd -P)
if GIT_TOPLEVEL=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) &&
    [ "$(CDPATH= cd -- "$GIT_TOPLEVEL" && pwd -P)" = "$PROJECT_DIR_PHYSICAL" ] &&
    [ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=normal)" ] &&
    [ "$allow_dirty" = false ]; then
    fail "the working tree has uncommitted changes. Commit them first (the bundle records the commit it was built from), or pass --allow-dirty for a rehearsal you will not distribute."
fi

VERSION=$(plist_value "$INFO_PLIST" CFBundleShortVersionString)
BUILD=$(plist_value "$INFO_PLIST" CFBundleVersion)
DMG_NAME="Audio Level Bar-$VERSION.dmg"
ZIP_NAME="Audio Level Bar-$VERSION.zip"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"

mkdir -p "$DIST_DIR"
WORK_DIR=$(mktemp -d "$DIST_DIR/.audio-level-bar-release.XXXXXX")

# Without the local pattern list the scanner checks only the generic shapes,
# and says so in a note. A release gate that cannot check the values this Mac
# must never publish has not checked anything that matters, so it stops here.
if ! printf '' | "$SCAN_SCRIPT" "release preflight" 2>"$WORK_DIR/preflight.err"; then
    cat "$WORK_DIR/preflight.err" >&2
    fail "the scanner refused empty input"
fi
if grep -q '^note ' "$WORK_DIR/preflight.err"; then
    cat "$WORK_DIR/preflight.err" >&2
    fail "the private pattern list is missing or holds no values. Run make setup-dev and write the values this Mac must never publish into .local/private-patterns.txt, or point ALB_PRIVATE_PATTERNS at that list."
fi

# ---- Clean output directory -----------------------------------------------

case "$RELEASE_DIR" in
    "$PROJECT_DIR"/dist/release) ;;
    *) fail "unexpected release directory" ;;
esac
if [ -e "$RELEASE_DIR" ] || [ -L "$RELEASE_DIR" ]; then
    [ ! -L "$RELEASE_DIR" ] || fail "$RELEASE_DIR is a symbolic link"
    rm -rf "$RELEASE_DIR"
fi
RELEASE_DIR_OWNED=true
mkdir "$RELEASE_DIR"

# ---- Build -----------------------------------------------------------------

step "Building Audio Level Bar $VERSION (build $BUILD) for distribution"
AUDIO_LEVEL_BAR_DISTRIBUTION=true \
    AUDIO_LEVEL_BAR_APP_BUNDLE="$APP_BUNDLE" \
    AUDIO_LEVEL_BAR_BUILD_DIR="$SCRATCH_DIR" \
    "$BUILD_SCRIPT"
[ -d "$APP_BUNDLE" ] || fail "the build left no bundle at $APP_BUNDLE"

# ---- Build-machine paths ---------------------------------------------------

step "Checking the executable for build-machine paths"
home_paths=$(LC_ALL=C grep -a -o '/Users/[A-Za-z0-9._-]*' "$EXECUTABLE" | wc -l | tr -d ' ')
debug_entries=$(nm -ap "$EXECUTABLE" | awk '$2 == "-" && ($5 == "SO" || $5 == "OSO")' | wc -l | tr -d ' ')
project_paths=0
for directory in "$PROJECT_DIR" "$PROJECT_DIR_PHYSICAL" "$SCRATCH_DIR"; do
    count=$(LC_ALL=C grep -a -o -F -- "$directory" "$EXECUTABLE" | wc -l | tr -d ' ')
    project_paths=$((project_paths + count))
done
printf '%s\n' \
    "Home directory paths (under /Users): $home_paths" \
    "Debug symbol entries (SO and OSO stabs): $debug_entries" \
    "Occurrences of the build directories: $project_paths"
[ "$home_paths" -eq 0 ] && [ "$debug_entries" -eq 0 ] && [ "$project_paths" -eq 0 ] ||
    fail "the executable still names the machine it was built on"

# ---- Notarize and staple the app ------------------------------------------

if [ -n "$notary_profile" ]; then
    submission_zip="$WORK_DIR/notarize-app.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$submission_zip"
    notarize "$submission_zip" app
    step "Stapling the notarization ticket to the app"
    staple "$APP_BUNDLE"
    STAPLED_APP=true
fi

# ---- Verify and scan the final bundle --------------------------------------

step "Verifying the bundle"
"$VERIFY_SCRIPT" "$APP_BUNDLE"
app_fingerprint=$(bundle_fingerprint "$APP_BUNDLE")

step "Scanning every file in the bundle with scripts/scan-private-content.sh"
scan_bundle "$APP_BUNDLE" "app bundle"

step "Scanning the code signature (reported, not a gate)"
report_signature

step "Gatekeeper assessment of the app"
gatekeeper app --type execute "$APP_BUNDLE"

# ---- Disk image ------------------------------------------------------------

if [ "$make_dmg" = true ]; then
    step "Creating $DMG_NAME"
    image_root="$WORK_DIR/image"
    mkdir "$image_root"
    ditto "$APP_BUNDLE" "$image_root/$APP_NAME"
    ln -s /Applications "$image_root/Applications"
    hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$image_root" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG_PATH"

    step "Signing the disk image"
    if [ -n "$identity" ]; then
        codesign --force --timestamp --sign "$identity" "$DMG_PATH"
    else
        codesign --force --sign - "$DMG_PATH"
    fi
    codesign --verify --strict --verbose=2 "$DMG_PATH"

    if [ -n "$notary_profile" ]; then
        notarize "$DMG_PATH" disk-image
        step "Stapling the notarization ticket to the disk image"
        staple "$DMG_PATH"
    fi
    step "Gatekeeper assessment of the disk image"
    gatekeeper "disk image" --type open --context context:primary-signature "$DMG_PATH"

    step "Verifying the disk image contents"
    MOUNT_POINT="$WORK_DIR/mount"
    mkdir "$MOUNT_POINT"
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$DMG_PATH"
    [ -L "$MOUNT_POINT/Applications" ] && [ "$(readlink "$MOUNT_POINT/Applications")" = /Applications ] ||
        fail "the disk image lacks the link to /Applications"
    # Exactly the app and the link, apart from what the file system keeps for
    # itself at the top of a volume.
    unexpected=$(cd "$MOUNT_POINT" && find . -mindepth 1 -maxdepth 1 -print |
        grep -v -x -e "./$APP_NAME" -e ./Applications -e ./.fseventsd -e ./.Trashes -e './.HFS+ Private Directory Data' || true)
    [ -z "$unexpected" ] || fail "the disk image holds more than the app and the Applications link"
    (cd "$MOUNT_POINT" && find . -print | LC_ALL=C sort) >"$WORK_DIR/image-names"
    scan_stdin "disk image: file names" <"$WORK_DIR/image-names" ||
        fail "private content in the disk image's file names"
    "$VERIFY_SCRIPT" "$MOUNT_POINT/$APP_NAME" >/dev/null
    [ "$(bundle_fingerprint "$MOUNT_POINT/$APP_NAME")" = "$app_fingerprint" ] ||
        fail "the app inside the disk image differs from the scanned bundle"
    echo "The disk image holds the scanned app, byte for byte, and the link to /Applications."
    detach_image
fi

# ---- ZIP archive -----------------------------------------------------------

if [ "$make_zip" = true ]; then
    step "Creating $ZIP_NAME"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    step "Verifying the archive contents"
    zipinfo -1 "$ZIP_PATH" | scan_stdin "archive: file names" ||
        fail "private content in the archive's file names"
    extracted="$WORK_DIR/extracted"
    mkdir "$extracted"
    ditto -x -k "$ZIP_PATH" "$extracted"
    unexpected=$(cd "$extracted" && find . -mindepth 1 -maxdepth 1 -print | grep -v -x "./$APP_NAME" || true)
    [ -z "$unexpected" ] || fail "the archive holds more than the app"
    "$VERIFY_SCRIPT" "$extracted/$APP_NAME" >/dev/null
    [ "$(bundle_fingerprint "$extracted/$APP_NAME")" = "$app_fingerprint" ] ||
        fail "the app inside the archive differs from the scanned bundle"
    echo "The archive holds the scanned app, byte for byte."
fi

# ---- Checksums -------------------------------------------------------------

step "Writing SHA-256 checksums"
(
    cd "$RELEASE_DIR"
    for name in "$DMG_NAME" "$ZIP_NAME"; do
        [ -f "$name" ] || continue
        shasum -a 256 "$name" >"$name.sha256"
        shasum -a 256 -c "$name.sha256"
    done
)

# ---- Summary ---------------------------------------------------------------

COMPLETED=true
git_commit=$(plist_value "$APP_BUNDLE/Contents/Info.plist" AudioLevelBarGitCommit)
git_state=$(plist_value "$APP_BUNDLE/Contents/Info.plist" AudioLevelBarGitState)
distributable=true
signature_info=$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)
# The authority is the certificate subject, a real name and Team ID for a
# Developer ID certificate, so it is classified here rather than printed.
if printf '%s\n' "$signature_info" | grep -Fx 'Signature=adhoc' >/dev/null; then
    signature_summary="ad hoc"
    distributable=false
elif printf '%s\n' "$signature_info" | grep -q "^Authority=$DEVELOPER_ID_APPLICATION: "; then
    signature_summary="Developer ID Application certificate, hardened runtime"
else
    signature_summary="a certificate that is not Developer ID Application, hardened runtime"
    distributable=false
fi
if [ -n "$notary_profile" ]; then
    notarization_summary="accepted and stapled (submission IDs:$NOTARIZED_IDS)"
else
    notarization_summary="not notarized"
    distributable=false
fi
[ "$git_state" = clean ] || distributable=false

step "Release"
printf '%s\n' \
    "Output directory: dist/release" \
    "Version/build: $VERSION ($BUILD)" \
    "Git commit/state: $git_commit ($git_state)" \
    "Build-machine paths in the executable: 0" \
    "Private-content scan of the bundle: no hits" \
    "Code signature: $signature_summary; $SIGNATURE_SCAN" \
    "Notarization: $notarization_summary"
(
    cd "$RELEASE_DIR"
    for name in "$DMG_NAME" "$ZIP_NAME"; do
        [ -f "$name" ] || continue
        printf '%s\n' "$name: SHA-256 $(awk '{print $1}' "$name.sha256")"
    done
)

if [ "$distributable" = true ]; then
    printf '\nDistributable: yes. Upload the files above with their .sha256 files.\n'
    exit 0
fi
printf '\nDistributable: NO. Do not hand this build to anyone:\n'
case "$signature_summary" in
    "ad hoc")
        printf -- '- It is signed ad hoc. Set CODESIGN_IDENTITY to your Developer ID Application certificate.\n'
        ;;
    "a certificate that is not"*)
        printf -- '- Its certificate is not a Developer ID Application certificate, which Gatekeeper on another Mac requires.\n'
        ;;
esac
if [ -z "$notary_profile" ]; then
    printf -- '- It is not notarized. Gatekeeper on another Mac refuses an app that is not; set NOTARY_PROFILE to the keychain profile created with "xcrun notarytool store-credentials".\n'
fi
if [ "$git_state" != clean ]; then
    printf -- '- It was built from a working tree in state %s.\n' "$git_state"
fi
