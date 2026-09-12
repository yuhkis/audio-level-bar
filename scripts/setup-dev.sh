#!/bin/sh
# Prepare a clone on a new machine: identity, hooks, and the local pattern file.
# Safe to re-run. Run this once per machine, right after cloning.
set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/* scripts/*.sh

# Identity is pinned per repository so that later changes to the global setting
# do not reach this clone. Pinning does not vet the address: copied from a
# global setting that carries a workplace address, it pins that address, which
# is why the result is printed at the end for the person running this to check.
# No identity is hardcoded here: a script that assigned one would make every
# contributor author commits under somebody else's name. An existing repo-local
# setting wins, then GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL from the environment,
# then the global setting.
local_email=$(git config --local --get user.email || true)

if [ -z "$local_email" ]; then
    name=${GIT_AUTHOR_NAME:-$(git config --global --get user.name || true)}
    email=${GIT_AUTHOR_EMAIL:-$(git config --global --get user.email || true)}
    if [ -n "$email" ]; then
        [ -n "$name" ] && git config user.name "$name"
        git config user.email "$email"
    else
        printf 'No Git identity found. Set one before committing:\n' >&2
        printf '  git config user.name  "Your Name"\n' >&2
        printf '  git config user.email "you@example.com"\n' >&2
        printf 'Gitのidentityが未設定です。コミット前に上記を設定してください。\n' >&2
    fi
fi

mkdir -p .local
if [ ! -f .local/private-patterns.txt ]; then
    cat >.local/private-patterns.txt <<'TEMPLATE'
# One string per line that must never be published. Matching is by substring,
# and ignores case for ASCII letters only: a value with accented or full-width
# letters needs each case form written out on its own line. This file is
# git-ignored: it is never committed and never pushed. Keep one on each machine.
#
# 公開してはならない文字列を1行に1つ書きます。部分一致で判定し、大文字小文字
# の区別を無視するのはASCII英字だけです。アクセント付きや全角の文字を含む値
# は、大文字と小文字の両方を別々の行に書いてください。このファイルは
# .gitignore 済みで、コミットも push もされません。各Macに1つずつ置きます。
#
# What belongs here: other people's names (family, colleagues, collaborators),
# each machine's host name, Apple Team IDs and certificate subjects, non-public
# organization, project or product names, the model names of hardware you own,
# internal URLs and hosts, account numbers and device serial numbers.
#
# 書くべきもの: 自分以外の氏名（家族・同僚・共同作業者）、各Macのホスト名、
# Apple Team IDと証明書subject、非公開の組織名・プロジェクト名・製品名、
# 所有機材の型番、内部URLやホスト、契約者番号や機器のシリアル番号。
#
# Write the literal value, one per line. The contents of this file are never
# printed in results; only line numbers are reported.
# 1行に1つ、実際の値をそのまま書きます。このファイルの中身は検査結果にも
# 表示されず、行番号だけが報告されます。
TEMPLATE
    printf 'created .local/private-patterns.txt — add the real values / 実際の値を追記してください\n'
fi

printf 'user.name      = %s\n' "$(git config user.name || echo '(unset)')"
printf 'user.email     = %s\n' "$(git config user.email || echo '(unset)')"
printf 'core.hooksPath = %s\n' "$(git config core.hooksPath)"
# The address above may have been copied from a global setting that was never
# meant for a public history. Nothing here can tell, so say what to look at.
printf 'Check that this address is one you are willing to publish; change it\n'
printf 'with: git config user.email "you@example.com"\n'
printf '公開してよいアドレスかどうかを確認してください。変更は上記のコマンドです。\n'
printf 'setup-dev done / 完了\n'
