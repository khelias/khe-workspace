#!/bin/bash
# Fixture tests for `scripts/workspace.sh running` and its quiet suffix: local
# bare remotes in a temporary folder, commits dated with GIT_COMMITTER_DATE,
# nothing on the network. Runs under macOS /bin/bash 3.2.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test

failures=0
now="$(date +%s)"
fresh="@$now +0000"
old="@$((now - 7 * 3600 - 300)) +0000"

expect_eq() {
    if [[ "$2" == "$3" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "     got: $2"
        failures=$((failures + 1))
    fi
}

# commit <dir> <date> <message> [<path>]: one commit at <date> of <path>, or
# of a change to file.txt.
commit() {
    local path="${4:-file.txt}"
    [[ -n "${4:-}" ]] || echo "$RANDOM" >>"$1/file.txt"
    git -C "$1" add "$path"
    GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$1" commit -q -m "$3"
}

# seed <dir> <date>: <dir> cloned from <dir>.git, one commit at <date> pushed to main.
seed() {
    git init -q --bare -b main "$1.git"
    git clone -q "$1.git" "$1" 2>/dev/null
    git -C "$1" symbolic-ref HEAD refs/heads/main
    commit "$1" "$2" one
    git -C "$1" push -q -u origin main
}

# plan <name> <date> <line>: a plan file whose Running line is <line>, pushed at <date>.
plan() {
    printf '# %s\n\n**Status:** running\n**Running:** %s\n' "$1" "$3" >"$meta/plans/$1.md"
    commit "$meta" "$2" "$1" "plans/$1.md"
}

root="$work/root"
seed "$root" "$old"
mkdir -p "$root/scripts" "$root/repos"
cp "$here/workspace.sh" "$root/scripts/workspace.sh"
meta="$root/repos/khe-meta"
seed "$meta" "$old"
mkdir -p "$meta/plans"

seed "$root/repos/fresh-repo" "$fresh"
seed "$root/repos/old-repo" "$old"
seed "$root/repos/remote-repo" "$old"
other="$work/remote-repo-other"
git clone -q "$root/repos/remote-repo.git" "$other" 2>/dev/null
git -C "$other" switch -q -c feature
commit "$other" "$fresh" feature
git -C "$other" push -q origin feature
git -C "$root/repos/remote-repo" fetch -q origin

plan fresh "$old" "laptop 2026-11-27 fresh-repo"
plan old "$old" "laptop 2026-11-27 old-repo"
plan remote "$old" "laptop 2026-11-27 remote-repo"
plan root "$old" "agent-vm 2026-11-27 khe-workspace"
plan missing "$old" "laptop 2026-11-27 not-cloned"
plan new-plan "$fresh" "laptop 2026-11-27 old-repo"
plan malformed "$fresh" "laptop yesterday old-repo"
git -C "$meta" push -q origin main
git -C "$meta" fetch -q origin

out="$("$root/scripts/workspace.sh" running 2>&1)"
rc=$?
expect_eq "exits 0 with a repo not cloned" "$rc" 0

line() { printf '%s\n' "$out" | grep "^$1: " || true; }
expect_eq "fresh commit: no suffix" "$(line fresh)" "fresh: laptop 2026-11-27 fresh-repo"
expect_eq "seven hours old: quiet 7h" "$(line old)" "old: laptop 2026-11-27 old-repo quiet 7h"
expect_eq "commit only on refs/remotes/origin counts" "$(line remote)" "remote: laptop 2026-11-27 remote-repo"
expect_eq "khe-workspace maps to the root" "$(line root)" "root: agent-vm 2026-11-27 khe-workspace quiet 7h"
expect_eq "repo not cloned: no suffix" "$(line missing)" "missing: laptop 2026-11-27 not-cloned"
expect_eq "fresh plan commit: no suffix" "$(line new-plan)" "new-plan: laptop 2026-11-27 old-repo"
expect_eq "malformed line dropped" "$(line malformed)" ""
expect_eq "six lines, the malformed one dropped" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 6

echo
if ((failures > 0)); then
    echo "$failures failed"
    exit 1
fi
echo "all passed"
