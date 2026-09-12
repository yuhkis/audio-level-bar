#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SCRATCH_DIR=${AUDIO_LEVEL_BAR_BUILD_DIR:-"$PROJECT_DIR/.build"}
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Audio Level Bar.app"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/Resources/AudioLevelBar.entitlements"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-app.sh"

case "$APP_BUNDLE" in
    "$PROJECT_DIR"/dist/*) ;;
    *)
        echo "Refusing to replace an app bundle outside this project's dist directory." >&2
        exit 1
        ;;
esac

EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
EXPECTED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")
SOURCE_LIST=$(mktemp "${TMPDIR:-/tmp}/audio-level-bar-sources.XXXXXX")
SOURCE_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/audio-level-bar-manifest.XXXXXX")
STAGING_ROOT=
PREVIOUS_APP=
DIST_TRANSACTION_ACTIVE=false
DIST_HAD_PREVIOUS=false
HAS_GIT_METADATA=false
PROJECT_DIR_PHYSICAL=$(CDPATH= cd -- "$PROJECT_DIR" && pwd -P)
if GIT_TOPLEVEL=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null); then
    GIT_TOPLEVEL_PHYSICAL=$(CDPATH= cd -- "$GIT_TOPLEVEL" && pwd -P)
    if [ "$GIT_TOPLEVEL_PHYSICAL" = "$PROJECT_DIR_PHYSICAL" ]; then
        HAS_GIT_METADATA=true
    fi
fi

rollback_dist() {
    [ "$DIST_TRANSACTION_ACTIVE" = true ] || return 0
    DIST_TRANSACTION_ACTIVE=false

    if [ -n "$PREVIOUS_APP" ] && [ -d "$PREVIOUS_APP" ]; then
        if [ -d "$APP_BUNDLE" ] && [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
            mv "$APP_BUNDLE" "$STAGING_ROOT/interrupted.app" 2>/dev/null || true
        fi
        if [ ! -e "$APP_BUNDLE" ]; then
            mv "$PREVIOUS_APP" "$APP_BUNDLE" 2>/dev/null || true
        fi
    elif [ "$DIST_HAD_PREVIOUS" = false ] &&
        [ -d "$APP_BUNDLE" ] && [ ! -d "$STAGED_APP" ] &&
        [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
        mv "$APP_BUNDLE" "$STAGING_ROOT/interrupted.app" 2>/dev/null || true
    fi
}

cleanup() {
    rollback_dist
    rm -f "$SOURCE_LIST" "$SOURCE_MANIFEST" || true
    if [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
        case "$STAGING_ROOT" in
            "$DIST_DIR"/.audio-level-bar-build.*) rm -rf "$STAGING_ROOT" || true ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

write_source_list() {
    if [ "$HAS_GIT_METADATA" = true ]; then
        git -C "$PROJECT_DIR" ls-files --cached --others --exclude-standard |
            LC_ALL=C sort > "$SOURCE_LIST"
    else
        (
            cd "$PROJECT_DIR"
            find . \
                \( -path './.git' -o -path './.build' -o -path './dist' \
                -o -path './.swiftpm' -o -path './.claude' -o -path './.local' \) \
                -prune -o \( -type f -o -type l \) -print |
                sed 's#^\./##' |
                LC_ALL=C sort
        ) > "$SOURCE_LIST"
    fi
}

write_source_manifest() {
    write_source_list
    (
        cd "$PROJECT_DIR"
        while IFS= read -r path; do
            if [ -L "$path" ]; then
                hash=$(readlink "$path" | shasum -a 256 | awk '{print $1}')
                printf 'symlink %s %s\n' "$hash" "$path"
            elif [ -f "$path" ]; then
                mode=$(stat -f '%Lp' "$path")
                hash=$(shasum -a 256 "$path" | awk '{print $1}')
                printf '%s %s %s\n' "$mode" "$hash" "$path"
            else
                printf 'other - %s\n' "$path"
            fi
        done < "$SOURCE_LIST"
    ) > "$SOURCE_MANIFEST"
}

source_state() {
    if [ "$HAS_GIT_METADATA" = false ]; then
        printf 'source-archive\n'
        return
    fi
    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=normal)" ]; then
        printf 'dirty\n'
    else
        printf 'clean\n'
    fi
}

if [ "$HAS_GIT_METADATA" = true ]; then
    GIT_COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD)
    COMMIT_EPOCH=$(git -C "$PROJECT_DIR" show -s --format=%ct HEAD)
    case "$COMMIT_EPOCH" in
        ''|*[!0-9]*)
            echo "Could not derive a deterministic provenance timestamp from HEAD." >&2
            exit 1
            ;;
    esac
    PROVENANCE_TIMESTAMP=$(date -u -r "$COMMIT_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
else
    GIT_COMMIT=source-archive
    PROVENANCE_TIMESTAMP=source-archive
fi
GIT_STATE=$(source_state)
write_source_manifest
SOURCE_FINGERPRINT=$(shasum -a 256 "$SOURCE_MANIFEST" | awk '{print $1}')

# A retained local deployment candidate must not reuse a version/build pair
# for a different snapshot. Ephemeral CI builds start without an earlier dist
# bundle and are distinguished by their embedded commit and fingerprint.
if [ -d "$APP_BUNDLE" ]; then
    existing_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
    existing_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
    if [ "$existing_version" = "$EXPECTED_VERSION" ] && [ "$existing_build" = "$EXPECTED_BUILD" ]; then
        existing_fingerprint=$(/usr/libexec/PlistBuddy -c 'Print :AudioLevelBarSourceFingerprint' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
        existing_commit=$(/usr/libexec/PlistBuddy -c 'Print :AudioLevelBarGitCommit' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
        existing_state=$(/usr/libexec/PlistBuddy -c 'Print :AudioLevelBarGitState' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
        if [ "$existing_fingerprint" != "$SOURCE_FINGERPRINT" ] ||
            [ "$existing_commit" != "$GIT_COMMIT" ] ||
            [ "$existing_state" != "$GIT_STATE" ]; then
            echo "Refusing to reuse Audio Level Bar $EXPECTED_VERSION build $EXPECTED_BUILD for changed source." >&2
            echo "The build number identifies a deployment candidate, not a commit: remove the retained candidate from dist/ and build again, or bump CFBundleVersion when a new candidate is actually being prepared." >&2
            exit 1
        fi
        if ! "$VERIFY_SCRIPT" "$APP_BUNDLE"; then
            echo "The retained candidate for this build number does not match the request (for example its signature); remove it from dist/ and build again, or bump CFBundleVersion when a new candidate is actually being prepared." >&2
            exit 1
        fi
        echo "$APP_BUNDLE"
        exit 0
    fi
fi

swift build \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    -c release

BIN_DIR=$(swift build \
    --package-path "$PROJECT_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    -c release \
    --show-bin-path)

if [ "$HAS_GIT_METADATA" = true ]; then
    FINAL_GIT_COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD)
else
    FINAL_GIT_COMMIT=source-archive
fi
FINAL_GIT_STATE=$(source_state)
write_source_manifest
FINAL_SOURCE_FINGERPRINT=$(shasum -a 256 "$SOURCE_MANIFEST" | awk '{print $1}')
if [ "$FINAL_GIT_COMMIT" != "$GIT_COMMIT" ] ||
    [ "$FINAL_GIT_STATE" != "$GIT_STATE" ] ||
    [ "$FINAL_SOURCE_FINGERPRINT" != "$SOURCE_FINGERPRINT" ]; then
    echo "Source state changed during the release build; no app bundle was replaced." >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
STAGING_ROOT=$(mktemp -d "$DIST_DIR/.audio-level-bar-build.XXXXXX")
STAGED_APP="$STAGING_ROOT/Audio Level Bar.app"
CONTENTS_DIR="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LICENSES_DIR="$CONTENTS_DIR/Resources/ThirdPartyLicenses/WebRTCNoiseSuppression"

mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/AudioLevelBar" "$MACOS_DIR/AudioLevelBar"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/LICENSE" "$CONTENTS_DIR/Resources/LICENSE"
for lproj in "$PROJECT_DIR"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$CONTENTS_DIR/Resources/"
done
mkdir -p "$LICENSES_DIR"
cp "$PROJECT_DIR"/ThirdParty/WebRTCNoiseSuppression/LICENSES/* "$LICENSES_DIR/"

/usr/libexec/PlistBuddy -c "Set :AudioLevelBarGitCommit $GIT_COMMIT" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AudioLevelBarGitState $GIT_STATE" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AudioLevelBarSourceFingerprint $SOURCE_FINGERPRINT" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AudioLevelBarProvenanceTimestamp $PROVENANCE_TIMESTAMP" "$CONTENTS_DIR/Info.plist"

# Signing is opt-in. The keychain may hold certificates that belong to another
# person or business, and silently picking one would publish this app under
# their identity. Set CODESIGN_IDENTITY to sign with a specific certificate you
# own; leave it unset for ad-hoc signing. Same contract as wkr-macos.
identity=${CODESIGN_IDENTITY:-}

if [ -n "$identity" ] && [ "$identity" != '-' ]; then
    printf 'Signing with requested identity: %s\n' "$identity"
    # The hardened runtime denies microphone input to a process without the
    # audio-input entitlement, so a certificate signature always carries it.
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$identity" "$STAGED_APP"
else
    printf 'Using ad-hoc signing (set CODESIGN_IDENTITY to sign with your own certificate).\n'
    printf 'A rebuild may require microphone and system audio recording permission to be granted again.\n'
    # Count them rather than print them: a certificate subject carries a real
    # name and Team ID, which is exactly the class of value this project's own
    # scanner refuses to let into the repository or into build output.
    available=$(security find-identity -v -p codesigning 2>/dev/null |
        awk '/"(Apple Development|Developer ID Application):/{count++} END {print count + 0}')
    case "$available" in
        ''|*[!0-9]*) available=0 ;;
    esac
    if [ "$available" -gt 0 ]; then
        printf 'This keychain holds %s code signing certificate(s); CODESIGN_IDENTITY has to name one explicitly, and only one issued to you.\n' "$available"
        printf 'List them with: security find-identity -v -p codesigning\n'
    fi
    codesign --force --deep --sign - "$STAGED_APP"
fi
"$VERIFY_SCRIPT" "$STAGED_APP"

PREVIOUS_APP="$STAGING_ROOT/previous.app"
if [ -d "$APP_BUNDLE" ]; then
    DIST_HAD_PREVIOUS=true
fi
DIST_TRANSACTION_ACTIVE=true
if [ "$DIST_HAD_PREVIOUS" = true ]; then
    mv "$APP_BUNDLE" "$PREVIOUS_APP"
fi

if ! mv "$STAGED_APP" "$APP_BUNDLE"; then
    rollback_dist
    echo "Could not place the verified bundle in dist; the previous bundle was restored." >&2
    exit 1
fi

if ! "$VERIFY_SCRIPT" "$APP_BUNDLE"; then
    rollback_dist
    echo "The final dist verification failed; the previous bundle was restored." >&2
    exit 1
fi

DIST_TRANSACTION_ACTIVE=false
echo "$APP_BUNDLE"
