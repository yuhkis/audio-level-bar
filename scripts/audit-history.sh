#!/bin/sh
# Audit every ref, commit, blob, and annotated tag before making the repository
# public.
#
# The hooks guard what leaves this machine from now on. This audits what is
# already in the object database, including history that arrived before the
# hooks existed. Run it before flipping the repository to public and before
# pushing to a new remote.
set -eu
# Read bytes, not characters, like the scanner this feeds. In a UTF-8 locale
# the system sed and sort give up on input holding an invalid byte, so one
# Latin-1 identity or file name could empty the identity or file-name scan.
LC_ALL=C
export LC_ALL

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

scan=scripts/scan-private-content.sh
# Fail closed. `make setup-dev` creates the hook path and the scanner together,
# so a missing or non-executable scanner means this clone is not set up, not
# that there is nothing to check — and 検出なし from an audit that ran no
# scanner would be read as a clean history.
if [ ! -x "$scan" ]; then
    printf 'BLOCKED the content scanner is missing or not executable: %s\n' "$scan" >&2
    printf 'BLOCKED 検査スクリプトが無いか実行権限がありません: %s\n' "$scan" >&2
    printf '  Run: make setup-dev / make setup-dev を実行してください\n' >&2
    exit 1
fi
status=0

run() {
    "$@" || status=1
}

# Pull-request refs are server-side and invisible to --all until fetched, yet
# they are permanent: a branch deletion does not remove them, which makes them
# the one publication path that cannot be undone afterwards. Fetch them into a
# remote-tracking namespace so every scan below covers them too.
#
# They are removed again on the way out. Left in place they would be published
# by a later `git push --mirror` from this clone, as refs of its own.
#
# A fetch that fails is a failed audit, not a note: the result would say 検出
# なし about objects it never read. Set ALB_AUDIT_SKIP_PR_REFS=1 to audit a
# clone deliberately without them.
cleanup_pr_refs() {
    fetched_refs=$(git for-each-ref --format='%(refname)' refs/remotes/pr 2>/dev/null || true)
    [ -n "$fetched_refs" ] || return 0
    printf '%s\n' "$fetched_refs" | while IFS= read -r ref; do
        git update-ref -d "$ref" 2>/dev/null || true
    done
}

if [ -n "${ALB_AUDIT_SKIP_PR_REFS:-}" ]; then
    printf 'note: ALB_AUDIT_SKIP_PR_REFS is set; refs/pull/*/head are not audited\n' >&2
elif git remote get-url origin >/dev/null 2>&1; then
    trap cleanup_pr_refs EXIT
    if ! git fetch --quiet origin '+refs/pull/*/head:refs/remotes/pr/*' 2>/dev/null; then
        printf 'BLOCKED refs/pull/*/head could not be fetched from origin\n' >&2
        printf '  A PR head ref survives the deletion of its branch, so an audit\n' >&2
        printf '  that skipped them says nothing about what is already published.\n' >&2
        status=1
    fi
else
    printf 'note: origin is not set; refs/pull/*/head are not audited. Point origin\n' >&2
    printf '  at the repository being published and run this again before publishing.\n' >&2
fi

# Commit authors and committers, plus the taggers of annotated tags under
# refs/tags. A nested or unnamed tag's tagger is still covered by the tag-object
# scan below, which reads every tag object itself.
identities() {
    git log --all --no-show-signature --format='%an <%ae>%n%cn <%ce>'
    git for-each-ref refs/tags \
        --format='%(if)%(taggername)%(then)%(taggername) %(taggeremail)%(end)'
}

printf '=== refs ===\n'
git for-each-ref --format='%(refname)  %(objectname:short)'
printf '\n=== identities across all refs ===\n'
identities | sed '/^$/d' | sort -u

printf '\n=== scanning ===\n'
# Ref names are published with the objects they point at, and a branch or
# lightweight tag name belongs to no object, so nothing below would see it.
run sh -c "git for-each-ref --format='%(refname)' | $scan 'ref names'"
identities | sed '/^$/d' | sort -u | "$scan" 'identities' || status=1
run sh -c "git log --all --no-show-signature --format='%B' | $scan 'commit messages'"
# core.quotePath=false keeps non-ASCII names literal, so a pattern written in,
# say, Japanese can still match a file name.
run sh -c "git rev-list --all | while read -r c; do git -c core.quotePath=false ls-tree -r --name-only \"\$c\"; done | sort -u | $scan 'file names'"
# The walk above visits commits only. A ref that points straight at a tree or
# a blob — a tag of a tree, say — has no commit for it to visit, so the names
# under such a ref come from the object walk instead, which starts from every
# ref whatever it points at. It lists each object under one name only, so it
# supplements the commit walk rather than replacing it.
run sh -c "git -c core.quotePath=false rev-list --objects --all \
    | sed -n 's/^[0-9a-f]* //p' \
    | sort -u \
    | $scan 'object paths'"

# An annotated tag is an object of its own. Its tagger and message appear in no
# commit, so neither the identity nor the message scan above sees them.
# rev-list --objects --all reaches every tag object, nested ones included.
run sh -c "git rev-list --objects --all \
    | awk '{print \$1}' \
    | git cat-file --batch-check='%(objectname) %(objecttype)' \
    | awk '\$2 == \"tag\" { print \$1 }' \
    | git cat-file --batch \
    | $scan 'tag objects'"

# Every blob ever written, with no size threshold. A size cap sounds harmless
# and is not: the objects it exempts are the large ones, which here means the
# vendored static library and anything else compiled or archived. A builder's
# home path baked into such a file is exactly what belongs in this net.
run sh -c "git rev-list --objects --all \
    | awk '{print \$1}' \
    | git cat-file --batch-check='%(objectname) %(objecttype)' \
    | awk '\$2 == \"blob\" { print \$1 }' \
    | git cat-file --batch \
    | $scan 'blob contents'"

printf '\n'
if [ "$status" -eq 0 ]; then
    printf 'audit-history: 検出なし\n'
else
    printf 'audit-history: 上記を解消するまで公開しないでください\n' >&2
fi
exit "$status"
