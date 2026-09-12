#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
SOURCES_DIR="$PROJECT_DIR/Sources"
RESOURCES_DIR="$PROJECT_DIR/Resources"
LOCALIZATIONS="en ja"
DEVELOPMENT_LOCALIZATION=en
INFO_PLIST_KEYS="NSMicrophoneUsageDescription NSAudioCaptureUsageDescription"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/audio-level-bar-localization.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

STATUS=0

report() {
    echo "$*" >&2
    STATUS=1
}

# The lookup key is the English wording, so the call sites are the authority for
# what every table has to contain. Newlines are folded first so that a call
# wrapped across lines is still found.
write_used_keys() {
    find "$SOURCES_DIR" -type f -name '*.swift' -print0 |
        xargs -0 cat |
        tr '\n' ' ' |
        grep -oE 'localized\( *"([^"\\]|\\.)*"' |
        sed -e 's/^localized( *"//' -e 's/"$//' |
        LC_ALL=C sort -u
}

write_table_entries() {
    plutil -convert xml1 -o - "$1" | awk '
        function decode(text) {
            gsub(/&lt;/, "<", text)
            gsub(/&gt;/, ">", text)
            gsub(/&quot;/, "\"", text)
            gsub(/&apos;/, "'"'"'", text)
            gsub(/&amp;/, "\\&", text)
            return text
        }
        function strip(text, tag) {
            sub("^[ \t]*<" tag ">", "", text)
            sub("</" tag ">[ \t]*$", "", text)
            return text
        }
        /<key>/ {
            key = decode(strip($0, "key"))
            if (getline <= 0) {
                next
            }
            value = decode(strip($0, "string"))
            printf "%s\t%s\n", key, value
        }
    '
}

compare_keys() {
    localization=$1
    table=$2
    expected=$3
    actual=$4

    missing=$(LC_ALL=C comm -23 "$expected" "$actual")
    orphaned=$(LC_ALL=C comm -13 "$expected" "$actual")

    if [ -n "$missing" ]; then
        report "$localization.lproj/$table is missing keys used in the source:"
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
    fi
    if [ -n "$orphaned" ]; then
        report "$localization.lproj/$table has keys no source file uses:"
        printf '%s\n' "$orphaned" | sed 's/^/  /' >&2
    fi
}

[ -d "$SOURCES_DIR" ] || {
    echo "Sources directory not found at $SOURCES_DIR" >&2
    exit 1
}

write_used_keys > "$WORK_DIR/used-keys"

if [ ! -s "$WORK_DIR/used-keys" ]; then
    report "no localized() call sites were found; the extractor is probably broken"
fi

for localization in $LOCALIZATIONS; do
    lproj="$RESOURCES_DIR/$localization.lproj"
    strings_file="$lproj/Localizable.strings"
    info_plist_strings="$lproj/InfoPlist.strings"

    if [ ! -f "$strings_file" ]; then
        report "missing $localization.lproj/Localizable.strings"
        continue
    fi
    if [ ! -f "$info_plist_strings" ]; then
        report "missing $localization.lproj/InfoPlist.strings"
        continue
    fi

    plutil -lint "$strings_file" >/dev/null ||
        report "$localization.lproj/Localizable.strings is not a valid strings file"
    plutil -lint "$info_plist_strings" >/dev/null ||
        report "$localization.lproj/InfoPlist.strings is not a valid strings file"

    write_table_entries "$strings_file" > "$WORK_DIR/$localization-entries"
    cut -f 1 "$WORK_DIR/$localization-entries" | LC_ALL=C sort -u > "$WORK_DIR/$localization-keys"

    duplicates=$(cut -f 1 "$WORK_DIR/$localization-entries" | LC_ALL=C sort | LC_ALL=C uniq -d)
    if [ -n "$duplicates" ]; then
        report "$localization.lproj/Localizable.strings defines a key more than once:"
        printf '%s\n' "$duplicates" | sed 's/^/  /' >&2
    fi

    compare_keys "$localization" Localizable.strings "$WORK_DIR/used-keys" "$WORK_DIR/$localization-keys"

    empty=$(awk -F '\t' '$2 == "" { print $1 }' "$WORK_DIR/$localization-entries")
    if [ -n "$empty" ]; then
        report "$localization.lproj/Localizable.strings has empty translations:"
        printf '%s\n' "$empty" | sed 's/^/  /' >&2
    fi

    # The development localization is what the key already says. Keeping it an
    # identity table means a reworded key cannot silently keep an old English
    # translation alive.
    if [ "$localization" = "$DEVELOPMENT_LOCALIZATION" ]; then
        diverged=$(awk -F '\t' '$1 != $2 { print $1 }' "$WORK_DIR/$localization-entries")
        if [ -n "$diverged" ]; then
            report "$localization.lproj/Localizable.strings must map each key to itself:"
            printf '%s\n' "$diverged" | sed 's/^/  /' >&2
        fi
    fi

    write_table_entries "$info_plist_strings" | cut -f 1 | LC_ALL=C sort -u > "$WORK_DIR/$localization-info-keys"
    printf '%s\n' $INFO_PLIST_KEYS | LC_ALL=C sort -u > "$WORK_DIR/expected-info-keys"
    compare_keys "$localization" InfoPlist.strings "$WORK_DIR/expected-info-keys" "$WORK_DIR/$localization-info-keys"
done

if [ "$STATUS" -eq 0 ]; then
    echo "Localization tables match $(wc -l < "$WORK_DIR/used-keys" | tr -d ' ') keys used in the source."
fi

exit "$STATUS"
