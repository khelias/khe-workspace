#!/usr/bin/env bash
# Read the agent loop's measures from the plan files, git and GitHub.
#
#   scripts/agent-metrics.sh [--plans <dir>] [--since <YYYY-MM-DD>]
#
# Covers the plans in <dir> (default repos/khe-meta/plans) first committed on
# or after <since> (default 30 days ago; a plan outside git counts from its
# mtime) that have a **Caught:** line, which the retro skill writes:
#   - the sums of each check on that line, with `-` (did not run) and
#     `pending` counted apart, and the push outcomes;
#   - plan to push: the plan file's first commit to the earliest CI run on
#     main whose head contains the plan's last sha in each repo;
#   - change failure rate: plans with a revert of one of their shas, or of
#     the merge commit that brought it, within 14 days, over plans pushed;
#     time to restore is the revert's first run minus the reverted one's;
#   - possible rework, not in the rate: later fix commits within 14 days
#     that touch the plan's files.
# Shas come from the plan's **Status:** line as `<repo> \`<sha>\`` pairs.
# Read-only. Run it outside the sandbox: it calls gh and reads remote refs,
# which sandboxed git may not see. Fetch the repos first for current numbers.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/repos/repos.yaml"
plans="$root/repos/khe-meta/plans"
since=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plans) plans="${2:?--plans needs a directory}"; shift 2 ;;
        --since) since="${2:?--since needs a date}"; shift 2 ;;
        *) echo "usage: $0 [--plans <dir>] [--since <YYYY-MM-DD>]" >&2; exit 2 ;;
    esac
done
[[ -d "$plans" ]] || { echo "agent-metrics: no plans directory $plans" >&2; exit 2; }
command -v jq >/dev/null && command -v gh >/dev/null ||
    { echo "agent-metrics: needs jq and gh" >&2; exit 2; }

day=86400
window=$((14 * day))
if [[ -n "$since" ]]; then
    since_s="$(jq -n --arg d "$since" '$d + "T00:00:00Z" | fromdateiso8601' 2>/dev/null)" ||
        { echo "agent-metrics: --since wants YYYY-MM-DD" >&2; exit 2; }
else
    since_s=$(($(date +%s) - 30 * day))
fi

tmp="$(mktemp -d)" || exit 2
trap 'rm -r -f -- "$tmp"' EXIT
: > "$tmp/rows"; : > "$tmp/plans"; : > "$tmp/notes"; : > "$tmp/reverts"; : > "$tmp/rework"

note() { printf '  %s: %s\n' "$1" "$2" >> "$tmp/notes"; }
dur() { printf '%dd %dh %dm' $(($1 / day)) $(($1 % day / 3600)) $(($1 % 3600 / 60)); }

# khe was khe-workspace's name until 2026-10-07; khelias is never cloned here.
known="$(awk '/^[[:space:]]*- name:/ { print $3 }' "$manifest" | tr '\n' ' ') khe khe-workspace khelias"

repo_dir() {
    case "$1" in
        khe-workspace) printf '%s' "$root" ;;
        *) [[ -d "$root/repos/$1/.git" ]] && printf '%s' "$root/repos/$1" ;;
    esac
    return 0
}

# The remote default branch, which is what was pushed.
main_ref() {
    git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null ||
        { git -C "$1" rev-parse -q --verify origin/main >/dev/null && printf 'origin/main'; }
}

# Prints "repo<TAB>sha" per pair in the Status line and "note<TAB>text" for
# what it skips. A `;` ends a repo's list; a sha with no repo before it in
# its part (an addendum, a branch name) is skipped.
status_pairs() {
    awk -v known="$known" '
        BEGIN { n = split(known, k, " "); for (i = 1; i <= n; i++) isrepo[k[i]] = 1 }
        /^\*\*Status:\*\*/ {
            s = $0; sub(/^\*\*Status:\*\*[[:space:]]*/, "", s); gsub(/;/, " ; ", s)
            n = split(s, t, /[[:space:]]+/); cur = ""
            for (i = 1; i <= n; i++) {
                w = t[i]
                if (w == ";") { cur = ""; continue }
                if (w ~ /`/) {
                    v = w; gsub(/^[^`]*`|`[^`]*$/, "", v)
                    if (length(v) >= 7 && length(v) <= 40 && v ~ /^[0-9a-f]+$/) {
                        if (cur != "") print cur "\t" v
                        else print "note\t`" v "` names no repo, skipped"
                    } else print "note\t`" v "` is not a sha, skipped"
                    continue
                }
                gsub(/^\(|[),.:]+$/, "", w)
                if (w in isrepo) cur = (w == "khe" ? "khe-workspace" : w)
            }
            exit
        }' "$1"
}

plan_start() {
    local f="$1" t
    t="$(git -C "$(dirname "$f")" log --follow --diff-filter=A --format=%ct -- "$(basename "$f")" 2>/dev/null | tail -n 1)"
    [[ -n "$t" ]] || t="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")"
    printf '%s' "$t"
}

labels=("plan review" "plan check" "code review" "security review" "operator")
sum_n=(0 0 0 0 0); sum_d=(0 0 0 0 0); not_run=(0 0 0 0 0); pending=(0 0 0 0 0)
outcomes=(unchanged changed discarded pending); push_n=(0 0 0 0)
no_line=()

# Pass 1: the Caught sums, and every resolvable sha as plan, repo, sha, time.
for f in "$plans"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    start="$(plan_start "$f")"
    [[ "$start" -ge "$since_s" ]] || continue
    caught="$(grep -m 1 '^\*\*Caught:\*\*' "$f")"
    if [[ -z "$caught" ]]; then
        no_line+=("$name")
        continue
    fi
    printf '%s\t%s\n' "$name" "$start" >> "$tmp/plans"

    for i in "${!labels[@]}"; do
        re="(^|[;[:space:]])${labels[$i]}[[:space:]]+([0-9]+|-|pending)([[:space:]]+\(([0-9]+)[[:space:]]+dropped\))?"
        if [[ ! "$caught" =~ $re ]]; then
            note "$name" "Caught line has no ${labels[$i]}"
            continue
        fi
        case "${BASH_REMATCH[2]}" in
            -) not_run[$i]=$((not_run[$i] + 1)) ;;
            pending) pending[$i]=$((pending[$i] + 1)) ;;
            *) sum_n[$i]=$((sum_n[$i] + BASH_REMATCH[2])); sum_d[$i]=$((sum_d[$i] + ${BASH_REMATCH[4]:-0})) ;;
        esac
    done
    found=
    for i in "${!outcomes[@]}"; do
        [[ "$caught" =~ push[[:space:]]+${outcomes[$i]}([^a-z]|$) ]] || continue
        push_n[$i]=$((push_n[$i] + 1)) found=1
    done
    [[ -n "$found" ]] || note "$name" "Caught line has no push outcome"

    while IFS=$'\t' read -r repo sha; do
        if [[ "$repo" == note ]]; then note "$name" "$sha"; continue; fi
        dir="$(repo_dir "$repo")"
        if [[ -z "$dir" ]]; then note "$name" "$repo is not cloned here, \`$sha\` skipped"; continue; fi
        full="$(git -C "$dir" rev-parse -q --verify "$sha^{commit}" 2>/dev/null)" ||
            { note "$name" "\`$sha\` not found in $repo"; continue; }
        printf '%s\t%s\t%s\t%s\n' "$name" "$repo" "$full" "$(git -C "$dir" show -s --format=%ct "$full")" >> "$tmp/rows"
    done < <(status_pairs "$f")
done

# Push runs on main per repo, oldest first, fetched once from the oldest sha
# on. Scheduled and manual runs are left out: they would crowd the push runs
# out of the 1000 that gh returns.
runs_file() {
    local repo="$1" f="$tmp/runs.$1" from
    if [[ ! -f "$f" ]]; then
        from="$(awk -F'\t' -v r="$repo" '$2 == r && (m == "" || $4 < m) { m = $4 } END { print m }' "$tmp/rows")"
        from="$(jq -rn --argjson s "${from:-0}" '$s - 86400 | todate[:10]')"
        gh run list --repo "khelias/$repo" --branch main --event push --limit 1000 --created ">=$from" \
            --json createdAt,headSha \
            --jq 'sort_by(.createdAt) | .[] | "\(.createdAt | fromdateiso8601)\t\(.headSha)"' > "$f" 2>/dev/null ||
            { echo "gh run list failed for $repo" > "$f.err"; : > "$f"; }
    fi
    printf '%s' "$f"
}

# The createdAt of the earliest run on main whose head contains the commit.
first_run() {
    local dir="$1" repo="$2" sha="$3" ct="$4" t h
    while IFS=$'\t' read -r t h; do
        [[ "$t" -ge "$ct" ]] || continue
        git -C "$dir" merge-base --is-ancestor "$sha" "$h" 2>/dev/null && { printf '%s' "$t"; return; }
    done < "$(runs_file "$repo")"
}

has_workflows() {
    git -C "$1" ls-tree -r --name-only "$2" -- .github/workflows 2>/dev/null | grep . >/dev/null
}

# The merge commit on main's first-parent line that brought the commit in,
# or nothing when it was pushed straight to main.
bringing_merge() {
    local dir="$1" main="$2" sha="$3"
    # grep reads to the end: with -q it would stop early, and pipefail would
    # turn rev-list's SIGPIPE into "not on the line".
    git -C "$dir" rev-list --first-parent "$main" | grep -x "$sha" >/dev/null && return
    git -C "$dir" rev-list --first-parent --ancestry-path --reverse "$sha..$main" | head -n 1
}

# Prints a line per revert of the commit within 14 days, with the time from
# the reverted commit's first CI run to the revert's.
reverts_of() {
    local name="$1" dir="$2" repo="$3" main="$4" ci="$5" target="$6" tct rev rct restore a b
    tct="$(git -C "$dir" show -s --format=%ct "$target")"
    while read -r rev rct; do
        [[ -n "$rev" ]] || continue
        restore=-
        if [[ -n "$ci" ]]; then
            a="$(first_run "$dir" "$repo" "$target" "$tct")"
            b="$(first_run "$dir" "$repo" "$rev" "$rct")"
            [[ -n "$a" && -n "$b" ]] && restore="$(dur $((b - a)))"
        fi
        printf '  %s: %s %s reverted by %s, time to restore %s\n' \
            "$name" "$repo" "${target:0:7}" "${rev:0:7}" "$restore"
    done < <(git -C "$dir" log "$main" --since=@"$tct" --until=@"$((tct + window))" \
        --format='%H %ct' --grep="This reverts commit $target")
}

# Pass 2, per plan: plan to push, reverts and possible rework.
plans_pushed=0
plans_reverted=0
: > "$tmp/push"
while IFS=$'\t' read -r name start; do
    repos="$(awk -F'\t' -v p="$name" '$1 == p { print $2 }' "$tmp/rows" | sort -u)"
    if [[ -z "$repos" ]]; then
        note "$name" "no sha in its Status line"
        printf '  %-48s -  (no shas)\n' "$name" >> "$tmp/push"
        continue
    fi
    unpushed="" reached=0 ci=0 missing="" reverted=""
    for repo in $repos; do
        dir="$(repo_dir "$repo")"
        main="$(main_ref "$dir")"
        if [[ -z "$main" ]]; then unpushed="$unpushed $repo (no origin/main here)"; continue; fi
        read -r last last_ct < <(awk -F'\t' -v p="$name" -v r="$repo" \
            '$1 == p && $2 == r && $4 >= m { m = $4; s = $3 } END { print s, m }' "$tmp/rows")
        if ! git -C "$dir" merge-base --is-ancestor "$last" "$main"; then
            unpushed="$unpushed $repo ${last:0:7}"
            continue
        fi
        repo_ci=
        if has_workflows "$dir" "$main"; then
            ci=1 repo_ci=1
            t="$(first_run "$dir" "$repo" "$last" "$last_ct")"
            if [[ -z "$t" ]]; then
                missing=1
                note "$name" "no CI run on $repo main contains \`${last:0:7}\`"
            elif [[ "$t" -gt "$reached" ]]; then
                reached="$t"
            fi
        fi

        files="$tmp/files"; : > "$files"; shas="$tmp/shas"; : > "$shas"
        lo="" hi=0
        while IFS=$'\t' read -r _ _ sha ct; do
            git -C "$dir" merge-base --is-ancestor "$sha" "$main" || continue
            echo "$sha" >> "$shas"
            git -C "$dir" show --name-only --format= "$sha" >> "$files"
            [[ -z "$lo" || "$ct" -lt "$lo" ]] && lo="$ct"
            [[ "$ct" -gt "$hi" ]] && hi="$ct"
            for target in "$sha" $(bringing_merge "$dir" "$main" "$sha"); do
                rv="$(reverts_of "$name" "$dir" "$repo" "$main" "$repo_ci" "$target")"
                [[ -n "$rv" ]] && { reverted=1; printf '%s\n' "$rv" >> "$tmp/reverts"; }
            done
        done < <(awk -F'\t' -v p="$name" -v r="$repo" '$1 == p && $2 == r' "$tmp/rows")

        [[ -n "$lo" ]] || continue
        paths=()
        while IFS= read -r p; do [[ -n "$p" ]] && paths+=(":(literal)$p"); done < <(sort -u "$files")
        [[ ${#paths[@]} -gt 0 ]] || continue
        while IFS=$'\t' read -r c subject; do
            grep -qx "$c" "$shas" && continue
            printf '  %s: %s %s %s\n' "$name" "$repo" "${c:0:7}" "$subject" >> "$tmp/rework"
        done < <(git -C "$dir" log "$main" --since=@"$lo" --until=@"$((hi + window))" \
            --format='%H%x09%s' -- "${paths[@]}" | grep -E $'\t''[Ff]ix')
    done

    if [[ -n "$unpushed" ]]; then
        printf '  %-48s not pushed (%s)\n' "$name" "${unpushed# }" >> "$tmp/push"
        continue
    fi
    plans_pushed=$((plans_pushed + 1))
    [[ -n "$reverted" ]] && plans_reverted=$((plans_reverted + 1))
    if [[ "$ci" -eq 0 ]]; then
        printf '  %-48s -  (no repo with CI)\n' "$name" >> "$tmp/push"
    elif [[ -n "$missing" ]]; then
        printf '  %-48s -  (CI run not found)\n' "$name" >> "$tmp/push"
    elif [[ "$reached" -lt "$start" ]]; then
        note "$name" "its commits reached main before the plan file's first commit"
        printf '  %-48s -  (pushed before the plan)\n' "$name" >> "$tmp/push"
    else
        printf '  %-48s %s\n' "$name" "$(dur $((reached - start)))" >> "$tmp/push"
    fi
done < "$tmp/plans"

for f in "$tmp"/runs.*.err; do [[ -f "$f" ]] && note "gh" "$(cat "$f")"; done

echo "Plans since $(jq -rn --argjson s "$since_s" '$s | todate[:10]') in $plans"
echo "  with a Caught line: $(wc -l < "$tmp/plans" | tr -d ' ')"
if [[ ${#no_line[@]} -gt 0 ]]; then
    for n in "${no_line[@]}"; do echo "  no line: $n"; done
fi
echo
echo "Caught, findings acted on (dropped; not run; pending)"
for i in "${!labels[@]}"; do
    printf '  %-16s %3d  (%d dropped; %d not run; %d pending)\n' \
        "${labels[$i]}" "${sum_n[$i]}" "${sum_d[$i]}" "${not_run[$i]}" "${pending[$i]}"
done
printf '  %-16s unchanged %d, changed %d, discarded %d, pending %d\n' push "${push_n[@]}"
echo
echo "Plan to push"
cat "$tmp/push"
echo
echo "Change failure rate: $plans_reverted of $plans_pushed pushed plans reverted within 14 days"
sort -u "$tmp/reverts"
echo
echo "Possible rework (fix commits within 14 days on the plan's files, not in the rate)"
if [[ -s "$tmp/rework" ]]; then sort -u "$tmp/rework"; else echo "  none"; fi
if [[ -s "$tmp/notes" ]]; then
    echo
    echo "Notes"
    cat "$tmp/notes"
fi
