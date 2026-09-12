#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
CANDIDATE=${1:-"$PROJECT_DIR/dist/Audio Level Bar.app"}
TARGET="/Applications/Audio Level Bar.app"
TARGET_PARENT=/Applications
VERIFY_SCRIPT="$SCRIPT_DIR/verify-app.sh"
STAGING_ROOT=
BACKUP=
FAILED=
TARGET_WAS_PRESENT=false
INSTALL_TRANSACTION_ACTIVE=false

fail() {
    echo "Installation refused: $*" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

bundle_fingerprint() {
    bundle=$1
    (
        cd "$bundle"
        find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            hash=$(shasum -a 256 "$file" | awk '{print $1}')
            printf '%s %s\n' "$hash" "$file"
        done
    ) | shasum -a 256 | awk '{print $1}'
}

rollback_install() {
    [ "$INSTALL_TRANSACTION_ACTIVE" = true ] || return 0
    INSTALL_TRANSACTION_ACTIVE=false

    if [ -d "$TARGET" ]; then
        if [ "$TARGET_WAS_PRESENT" = true ] && [ -d "$BACKUP" ] &&
            [ -n "$FAILED" ] && [ ! -e "$FAILED" ]; then
            mv "$TARGET" "$FAILED" 2>/dev/null || true
        elif [ "$TARGET_WAS_PRESENT" = false ] && [ ! -d "$STAGED_APP" ] &&
            [ -n "$FAILED" ] && [ ! -e "$FAILED" ]; then
            mv "$TARGET" "$FAILED" 2>/dev/null || true
        fi
    fi
    if [ "$TARGET_WAS_PRESENT" = true ] &&
        [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -e "$TARGET" ]; then
        mv "$BACKUP" "$TARGET" 2>/dev/null || true
    fi
}

cleanup() {
    rollback_install
    if [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
        case "$STAGING_ROOT" in
            /Applications/.audio-level-bar-install.*) rm -rf "$STAGING_ROOT" || true ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ ! -L "$CANDIDATE" ] || fail "candidate is a symbolic link"
"$VERIFY_SCRIPT" "$CANDIDATE"

if pgrep -x AudioLevelBar >/dev/null 2>&1; then
    fail "AudioLevelBar is running; quit every old and new copy before replacement"
fi

[ -d "$TARGET_PARENT" ] || fail "/Applications does not exist"
[ -w "$TARGET_PARENT" ] || fail "/Applications is not writable by the current user"
[ ! -L "$TARGET" ] || fail "$TARGET is a symbolic link"
if [ -e "$TARGET" ] && [ ! -d "$TARGET" ]; then
    fail "$TARGET exists but is not an app bundle directory"
fi

candidate_version=$(plist_value "$CANDIDATE" CFBundleShortVersionString)
candidate_build=$(plist_value "$CANDIDATE" CFBundleVersion)
candidate_fingerprint=$(bundle_fingerprint "$CANDIDATE")

if [ -d "$TARGET" ]; then
    target_version=$(plist_value "$TARGET" CFBundleShortVersionString)
    target_build=$(plist_value "$TARGET" CFBundleVersion)
    if [ "$target_version" = "$candidate_version" ] && [ "$target_build" = "$candidate_build" ]; then
        target_fingerprint=$(bundle_fingerprint "$TARGET")
        if [ "$target_fingerprint" != "$candidate_fingerprint" ]; then
            fail "$candidate_version build $candidate_build already exists with different contents; use a new build number"
        fi
        "$VERIFY_SCRIPT" "$TARGET"
        echo "Already installed and identical: $TARGET"
        exit 0
    fi
fi

STAGING_ROOT=$(mktemp -d "$TARGET_PARENT/.audio-level-bar-install.XXXXXX")
STAGED_APP="$STAGING_ROOT/Audio Level Bar.app"
ditto "$CANDIDATE" "$STAGED_APP"
"$VERIFY_SCRIPT" "$STAGED_APP"

staged_fingerprint=$(bundle_fingerprint "$STAGED_APP")
[ "$staged_fingerprint" = "$candidate_fingerprint" ] || fail "the staged copy differs from the candidate"

timestamp=$(date '+%Y%m%d-%H%M%S')
FAILED="$TARGET.failed-$timestamp"
[ ! -e "$FAILED" ] || fail "failed-install path already exists: $FAILED"
if [ -d "$TARGET" ]; then
    TARGET_WAS_PRESENT=true
    BACKUP="$TARGET.backup-$timestamp"
    [ ! -e "$BACKUP" ] || fail "backup path already exists: $BACKUP"
    INSTALL_TRANSACTION_ACTIVE=true
    mv "$TARGET" "$BACKUP"
else
    INSTALL_TRANSACTION_ACTIVE=true
fi

if ! mv "$STAGED_APP" "$TARGET"; then
    rollback_install
    fail "could not move the staged bundle into /Applications; previous bundle restored"
fi

if ! "$VERIFY_SCRIPT" "$TARGET"; then
    rollback_install
    fail "installed bundle verification failed; previous bundle restored and failed copy retained at $FAILED"
fi

installed_fingerprint=$(bundle_fingerprint "$TARGET")
if [ "$installed_fingerprint" != "$candidate_fingerprint" ]; then
    rollback_install
    fail "installed contents differ; previous bundle restored and failed copy retained at $FAILED"
fi

INSTALL_TRANSACTION_ACTIVE=false
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET" ||
        echo "Warning: Launch Services registration failed; the verified app remains installed." >&2
fi

echo "Installed: $TARGET"
if [ -n "$BACKUP" ]; then
    echo "Recoverable previous bundle: $BACKUP"
fi
