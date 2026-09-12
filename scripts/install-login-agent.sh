#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
VERIFY_SCRIPT="$SCRIPT_DIR/verify-app.sh"
INSTALLED_APP="/Applications/Audio Level Bar.app"
SOURCE_PLIST="$PROJECT_DIR/Resources/io.github.yuhkis.audio-level-bar.login.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
NEW_PLIST="$LAUNCH_AGENTS/io.github.yuhkis.audio-level-bar.login.plist"
NEW_LABEL=io.github.yuhkis.audio-level-bar.login
DOMAIN="gui/$(id -u)"
timestamp=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="$HOME/Library/Application Support/Audio Level Bar/Backups/login-agent-$timestamp"
HAD_PREVIOUS=false
HAD_NEW_PLIST=false
LOGIN_TRANSACTION_ACTIVE=false
NEW_PLIST_CREATED=false

fail() {
    echo "LaunchAgent installation refused: $*" >&2
    exit 1
}

bootout_label() {
    label=$1
    launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
}

restore_previous_files() {
    for saved in "$BACKUP_DIR"/*.plist; do
        [ -f "$saved" ] || continue
        destination="$LAUNCH_AGENTS/$(basename "$saved")"
        rm -f "$destination" || true
        mv "$saved" "$destination" 2>/dev/null || true
    done
    if [ "$NEW_PLIST_CREATED" = true ] && [ "$HAD_NEW_PLIST" = false ]; then
        rm -f "$NEW_PLIST" || true
    fi
}

restore_previous_jobs() {
    for plist in "$NEW_PLIST"; do
        if [ -f "$plist" ]; then
            launchctl bootstrap "$DOMAIN" "$plist" >/dev/null 2>&1 || true
        fi
    done
}

rollback() {
    [ "$LOGIN_TRANSACTION_ACTIVE" = true ] || return 0
    LOGIN_TRANSACTION_ACTIVE=false
    bootout_label "$NEW_LABEL"
    restore_previous_files
    restore_previous_jobs
}

cleanup() {
    rollback
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$VERIFY_SCRIPT" "$INSTALLED_APP"
if pgrep -x AudioLevelBar >/dev/null 2>&1; then
    fail "AudioLevelBar is running; quit it before switching login startup to the canonical bundle"
fi
plutil -lint "$SOURCE_PLIST" >/dev/null || fail "source plist is invalid"

source_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$SOURCE_PLIST")
source_program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$SOURCE_PLIST")
[ "$source_label" = "$NEW_LABEL" ] || fail "source plist label is unexpected"
[ "$source_program" = "$INSTALLED_APP" ] || fail "source plist does not open the canonical app"

for plist in "$NEW_PLIST"; do
    [ ! -L "$plist" ] || fail "refusing symbolic-link LaunchAgent: $plist"
    if [ -e "$plist" ]; then
        [ -f "$plist" ] || fail "LaunchAgent path is not a regular file: $plist"
        HAD_PREVIOUS=true
        if [ "$plist" = "$NEW_PLIST" ]; then
            HAD_NEW_PLIST=true
        fi
    fi
done

mkdir -p "$LAUNCH_AGENTS"
if [ "$HAD_PREVIOUS" = true ]; then
    [ ! -e "$BACKUP_DIR" ] || fail "backup path collision: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
fi

LOGIN_TRANSACTION_ACTIVE=true
bootout_label "$NEW_LABEL"

for plist in "$NEW_PLIST"; do
    if [ -e "$plist" ]; then
        mv "$plist" "$BACKUP_DIR/$(basename "$plist")"
    fi
done

NEW_PLIST_CREATED=true
cp "$SOURCE_PLIST" "$NEW_PLIST"
chmod 644 "$NEW_PLIST"

if ! launchctl bootstrap "$DOMAIN" "$NEW_PLIST"; then
    rollback
    fail "bootstrap failed; previous LaunchAgent files and jobs were restored"
fi

if ! launchctl print "$DOMAIN/$NEW_LABEL" >/dev/null 2>&1; then
    rollback
    fail "the new job was not visible after bootstrap; previous state was restored"
fi

LOGIN_TRANSACTION_ACTIVE=false
echo "Installed and loaded: $NEW_PLIST"
if [ "$HAD_PREVIOUS" = true ]; then
    echo "Recoverable LaunchAgent backup: $BACKUP_DIR"
fi
