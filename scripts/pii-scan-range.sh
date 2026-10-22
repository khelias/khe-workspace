#!/usr/bin/env bash
# Scan the commits in <base>..<head> of the repo in the current directory for
# personal data, with the rules the local commit gate uses (estate ADR-020).
#
#   scripts/pii-scan-range.sh <base> <head> [rules]
#
# rules defaults to $KHE_WORKSPACE/.claude/hooks/pii-rules.toml, and
# KHE_WORKSPACE to this script's checkout. Exit 0 clean, 1 on a finding
# (rule, commit, file and line printed, values redacted), 2 when the scan
# cannot run. CI runs it on a pull request's base and head shas.
#
# Each commit's added lines are scanned, so a line added and deleted again
# inside the range is still reported, and so are a merge's parents' lines.
# A merge commit shows only what its conflict resolution wrote beyond a
# clean remerge (--diff-merges=remerge; gitleaks may name such a file with a
# b/ prefix). Binary files show no lines.
# The commit messages are scanned as well. A .gitleaksignore in the repo or
# an inline gitleaks:allow cannot silence a finding: gitleaks reads history
# from the git dir, its ignore path is an empty directory, and inline allows
# are ignored. False positives go into the rules file's allowlists.
set -uo pipefail

[[ $# -ge 2 && $# -le 3 ]] || { echo "usage: $0 <base> <head> [rules]" >&2; exit 2; }
ws="${KHE_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
rules="${3:-$ws/.claude/hooks/pii-rules.toml}"
[[ -f "$rules" ]] || { echo "pii-scan: rules file $rules is missing" >&2; exit 2; }
rules="$(cd "$(dirname "$rules")" && pwd)/$(basename "$rules")"
command -v gitleaks >/dev/null && command -v jq >/dev/null ||
    { echo "pii-scan: needs gitleaks and jq" >&2; exit 2; }

# The git dir, not the working tree: gitleaks loads <source>/.gitleaksignore,
# and a commit cannot put one inside .git.
gitdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    { echo "pii-scan: not inside a git repository" >&2; exit 2; }
base="$(git rev-parse -q --verify "$1^{commit}")" &&
    head="$(git rev-parse -q --verify "$2^{commit}")" ||
    { echo "pii-scan: $1 or $2 is not a commit here" >&2; exit 2; }

tmp="$(mktemp -d)" || exit 2
trap 'rm -r -f -- "$tmp"' EXIT
mkdir "$tmp/ignore"

# The same hardening as the commit gate's gitleaks call
# (.claude/hooks/commit-gate.sh); change both together.
hits=
leaks() {
    local mode="$1" report="$2"; shift 2
    (cd "$tmp" && gitleaks "$mode" --config "$rules" --gitleaks-ignore-path "$tmp/ignore" \
        --redact --no-banner --no-color --log-level error --ignore-gitleaks-allow \
        --exit-code 3 --report-format json --report-path "$report" "$@") 2> "$report.err"
    local rc=$?
    [[ $rc -eq 3 ]] && hits="$hits $mode"
    [[ $rc -eq 0 || $rc -eq 3 ]] && return 0
    echo "pii-scan: gitleaks $mode failed (exit $rc)" >&2
    head -n 5 "$report.err" >&2
    exit 2
}

leaks git "$tmp/git.json" --log-opts "--diff-merges=remerge $base..$head" "$gitdir"

# One stdin run over every message, with a line-to-commit map beside it.
: > "$tmp/msg"; : > "$tmp/msg.map"
while read -r c; do
    git log -1 --format=%B "$c" | tee -a "$tmp/msg" | awk -v c="$c" '{ print c }' >> "$tmp/msg.map"
done < <(git rev-list "$base..$head")
[[ -s "$tmp/msg" ]] && leaks stdin "$tmp/msg.json" < "$tmp/msg"

found="$tmp/found"
: > "$found"
jq -r '.[] | "  \(.RuleID)  \(.Commit[:12])  \(.File):\(.StartLine)"' "$tmp/git.json" >> "$found" 2>/dev/null
if [[ -f "$tmp/msg.json" ]]; then
    while IFS=$'\t' read -r rule line; do
        printf '  %s  %s  commit message line\n' "$rule" "$(sed -n "${line}p" "$tmp/msg.map" | cut -c1-12)" >> "$found"
    done < <(jq -r '.[] | [.RuleID, .StartLine] | @tsv' "$tmp/msg.json" 2>/dev/null)
fi

[[ -s "$found" || -z "$hits" ]] ||
    echo "  a finding the gitleaks report did not name, in gitleaks$hits" >> "$found"
if [[ -s "$found" ]]; then
    echo "pii-scan: personal data in $base..$head (values redacted):"
    sort -u "$found"
    echo "Remove it from the branch history, or for a false positive add an allowlist"
    echo "entry with a reason to the rules file in khe-workspace."
    exit 1
fi
echo "pii-scan: $(git rev-list --count "$base..$head") commits in ${base:0:12}..${head:0:12} clean."
