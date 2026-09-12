#!/bin/sh
# Reject text that must never reach a public repository.
#
# Reads the text to scan on stdin. Exits non-zero when it finds something.
# The generic patterns below are safe to keep in a public repo because they
# describe shapes, not values. Anything that is itself sensitive — a person's
# name, a machine name, a certificate subject — belongs in the local pattern
# file instead, which is git-ignored and never leaves the machine.
set -eu
# Compare bytes, not characters. In a UTF-8 locale the system grep stops
# matching on a line at its first invalid byte, and binary blobs and Latin-1
# file names are full of them, so a value placed after one is never seen.
# Case-insensitive matching therefore folds ASCII letters only.
LC_ALL=C
export LC_ALL

label="${1:-input}"

# The default list belongs to the repository, not to one working tree, so that
# a linked worktree checks against the same values instead of silently having
# none. `git rev-parse --git-common-dir` names the main repository's .git
# directory from anywhere inside it, a linked worktree included.
if [ -n "${ALB_PRIVATE_PATTERNS:-}" ]; then
    patterns_file=$ALB_PRIVATE_PATTERNS
else
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
    case "$git_common_dir" in
        '' | .git) patterns_file=.local/private-patterns.txt ;;
        *) patterns_file="$git_common_dir/../.local/private-patterns.txt" ;;
    esac
fi
status=0
input=$(cat)

report() {
    printf 'BLOCKED [%s] %s\n' "$label" "$1" >&2
    status=1
}

# check <pattern> <reason> [allowed]
# `allowed` is an extended regex for forms that match <pattern> but are not
# private — standard macOS locations an installer must name, for instance.
# It is applied to each occurrence, not to each line: a line that names an
# allowed location as well as a private one is still a hit.
#
# Only line numbers are reported. Printing the matching line would reprint the
# private string into whatever reads this — a terminal, a CI log, an issue —
# and a home path or a certificate subject carries the very name the local
# pattern file exists to keep out of sight.
check() {
    set -- "$1" "$2" "${3:-}"
    if [ -n "$3" ]; then
        lines=$(printf '%s\n' "$input" | grep -anoEi -- "$1" |
            grep -avEi -- "$3" | cut -d: -f1 | uniq || true)
    else
        lines=$(printf '%s\n' "$input" | grep -anEi -- "$1" | cut -d: -f1 || true)
    fi
    if [ -n "$lines" ]; then
        report "$2"
        printf '    該当行: %s\n' \
            "$(printf '%s\n' "$lines" | head -5 | tr '\n' ' ')" >&2
    fi
}

check '/Users/[A-Za-z0-9._-]+' 'ホームディレクトリの絶対パス'
# A tilde- or $HOME-relative path names the same private location as an
# absolute one, and a ref once pushed to a shared remote may be impossible to
# remove, so both shapes are refused here rather than at review time.
# Require a real path shape — a leading delimiter and at least one directory
# separator — so that arbitrary bytes inside a binary blob do not match. The
# standard macOS locations an installer has to name are allowed through; what
# this is looking for is a path into someone's own working area.
#
# The delimiter class uses [[:blank:]] rather than \t, which a bracket
# expression reads as a backslash and a "t". It includes ':' for a PATH-style
# list, and any non-ASCII byte so that a path written straight after Japanese
# text or inside 「（ is still seen — DESIGN.md and ROADMAP.md are Japanese.
# $HOME may be followed by a closing quote, as in "$HOME"/…
check '(^|[[:blank:]"'"'"'`(=:]|[^ -~])~/[A-Za-z0-9._-]+/' 'ホーム相対パス（~/）' '~/(Library|Applications)/'
check '\$(HOME|\{HOME\})"?/[A-Za-z0-9._-]+/' 'ホーム相対パス（$HOME/）' '\$(HOME|\{HOME\})"?/(Library|Applications)/'
# The allowance above reaches one component deep, so a path that starts in an
# allowed location and then leaves it needs refusing on its own: a cloud-sync
# folder syncs whatever is named below it, and '..' walks straight back out.
# The '..' may sit any number of components down, so the component class
# allows a space — "Application Support" is one of the places it would hide.
check '(~|\$(HOME|\{HOME\})"?)/Library/(CloudStorage|Mobile Documents)' 'クラウド同期フォルダのホーム相対パス'
check '(~|\$(HOME|\{HOME\})"?)/(Library|Applications)/([A-Za-z0-9._ -]+/)*\.\.' '許可した場所から外へ出るホーム相対パス'
# Only the machine-local form is refused for everyone. A real organization's
# domain is one contributor's, and shipping it here would refuse every other
# person at that organization; such domains go in the local pattern file, or in
# `audiolevelbar.blockedEmailSuffixes` per clone.
check '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.local' 'ホスト名由来のメールアドレス（*.local）'
check '(Developer ID (Application|Installer)|Apple (Development|Distribution)|3rd Party Mac Developer):' 'Apple署名証明書のsubject（実名とTeam IDを含む）'
check 'BEGIN ([A-Z]+ )?PRIVATE KEY' '秘密鍵'
check '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}' 'GitHubトークン'
check 'AKIA[0-9A-Z]{16}' 'AWSアクセスキー'
check 'xox[baprs]-[A-Za-z0-9-]{10,}' 'Slackトークン'

# Values from the local list are matched literally and never echoed back —
# printing a blocked string would defeat the purpose of blocking it.
if [ -f "$patterns_file" ]; then
    line_number=0
    value_count=0
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        line_number=$((line_number + 1))
        case "$pattern" in
            '' | '#'*) continue ;;
        esac
        value_count=$((value_count + 1))
        if printf '%s\n' "$input" | grep -qiF -- "$pattern"; then
            report "非公開パターンに一致（$patterns_file の $line_number 行目）"
        fi
    done <"$patterns_file"
    # A file holding only the template comments checks nothing, and silence
    # there reads exactly like a clean result.
    if [ "$value_count" -eq 0 ]; then
        printf 'note [%s] %s に値が1つも書かれていないため、汎用パターンだけで検査しました\n' \
            "$label" "$patterns_file" >&2
    fi
else
    printf 'note [%s] %s が無いため、汎用パターンだけで検査しました\n' \
        "$label" "$patterns_file" >&2
fi

exit "$status"
