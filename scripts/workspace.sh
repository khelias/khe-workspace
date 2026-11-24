#!/usr/bin/env bash
# Clone, update or inspect the KHE repos listed in repos/repos.yaml.
#
#   scripts/workspace.sh clone    clone every missing repo into repos/<name>/
#   scripts/workspace.sh pull     fast-forward each clean repo on its current branch
#   scripts/workspace.sh status   branch, dirty files and ahead/behind per repo
#   scripts/workspace.sh sync     fast-forward each repo that is on a clean main,
#                                 one line for each that needs a look; the root is
#                                 only reported
#   scripts/workspace.sh running  the plans in khe-meta marked as running now
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/repos/repos.yaml"

# Emits "name<TAB>url<TAB>upstream" per entry. A line parser keeps the script
# dependency-free; repos.yaml documents the flat shape it expects.
entries() {
    awk '
        function flush() { if (name != "") print name "\t" url "\t" upstream; name = url = upstream = "" }
        /^[[:space:]]*- name:/ { flush(); sub(/.*name:[[:space:]]*/, ""); name = $0; next }
        /^[[:space:]]*url:/      { sub(/.*url:[[:space:]]*/, ""); url = $0; next }
        /^[[:space:]]*upstream:/ { sub(/.*upstream:[[:space:]]*/, ""); upstream = $0; next }
        END { flush() }
    ' "$manifest"
}

cmd_clone() {
    mkdir -p "$root/repos"
    while IFS=$'\t' read -r name url upstream; do
        target="$root/repos/$name"
        if [[ -d "$target/.git" ]]; then
            echo "  skip    $name"
            continue
        fi
        echo "  clone   $name"
        git clone --quiet "$url" "$target"
        if [[ -n "$upstream" ]]; then
            git -C "$target" remote add upstream "$upstream"
        fi
    done < <(entries)
}

cmd_pull() {
    while IFS=$'\t' read -r name _ _; do
        target="$root/repos/$name"
        if [[ ! -d "$target/.git" ]]; then
            echo "  missing $name (run clone)"
        elif [[ -n "$(git -C "$target" status --porcelain)" ]]; then
            echo "  dirty   $name (not pulled)"
        elif git -C "$target" pull --quiet --ff-only 2>/dev/null; then
            echo "  pulled  $name ($(git -C "$target" branch --show-current))"
        else
            echo "  failed  $name (no upstream branch or not a fast-forward)"
        fi
    done < <(entries)
}

cmd_status() {
    printf '  %-18s %-32s %6s %s\n' repo branch dirty ahead/behind
    while IFS=$'\t' read -r name _ _; do
        target="$root/repos/$name"
        if [[ ! -d "$target/.git" ]]; then
            printf '  %-18s %s\n' "$name" "(not cloned)"
            continue
        fi
        branch="$(git -C "$target" branch --show-current)"
        dirty="$(git -C "$target" status --porcelain | wc -l | tr -d ' ')"
        # pipefail turns a branch without an upstream into a fatal assignment.
        counts="$(git -C "$target" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null \
            | awk '{print "+" $2 "/-" $1}')" || counts=""
        printf '  %-18s %-32s %6s %s\n' "$name" "$branch" "$dirty" "${counts:-no upstream}"
    done < <(entries)
}

# Sync runs outside agent-vm's sandbox, and hooks, fsmonitor and the pager are
# commands a repo can carry, so no sync git call may start them.
sgit=(git --no-pager -c core.hooksPath=/dev/null -c core.fsmonitor=false)

sync_cleanup() {
    kill $(jobs -p) 2>/dev/null || true
    rmdir "$sync_lock" 2>/dev/null || true
}

sync_repo() {
    local name="$1" dir="$2" report_only="${3:-}" branch merged dirty counts behind ahead before
    branch="$("${sgit[@]}" -C "$dir" branch --show-current)" || return 1
    if [[ "$branch" != main ]]; then
        merged="not merged"
        if "${sgit[@]}" -C "$dir" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
            merged="merged"
        fi
        echo "  branch  $name (on ${branch:-a detached HEAD}, $merged into main)"
        return 0
    fi
    dirty="$("${sgit[@]}" -C "$dir" status --porcelain | wc -l | tr -d ' ')" || return 1
    counts="$("${sgit[@]}" -C "$dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)" || counts=""
    if [[ -z "$counts" ]]; then
        echo "  failed  $name (main has no upstream)"
        return 0
    fi
    read -r behind ahead <<<"$counts"
    if ((dirty > 0)); then
        echo "  dirty   $name (files: $dirty, behind: $behind, not updated)"
    elif ((ahead > 0)); then
        echo "  ahead   $name (ahead: $ahead, behind: $behind, not updated)"
    elif ((behind > 0)) && [[ -n "$report_only" ]]; then
        echo "  behind  $name (behind: $behind, pull it after reading what changed)"
    elif ((behind > 0)); then
        before="$("${sgit[@]}" -C "$dir" rev-parse HEAD)" || return 1
        if ! "${sgit[@]}" -C "$dir" merge --ff-only --quiet '@{upstream}' >/dev/null 2>&1; then
            echo "  failed  $name (fast-forward failed)"
        elif ! "${sgit[@]}" -C "$dir" diff --quiet "$before" HEAD -- ':(glob)**/package-lock.json'; then
            echo "  npm ci  $name (package-lock.json changed)"
        fi
    fi
}

cmd_sync() {
    # A desktop worktree of the root has a .git file and no repos of its own.
    [[ -d "$root/.git" ]] || return 0

    sync_lock="$root/.git/khe-sync.lock"
    if ! mkdir "$sync_lock" 2>/dev/null; then
        [[ -n "$(find "$sync_lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]] || return 0
        rmdir "$sync_lock" 2>/dev/null || return 0
        mkdir "$sync_lock" 2>/dev/null || return 0
    fi
    trap sync_cleanup EXIT
    trap 'exit 143' TERM INT HUP

    export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0

    local names=(khe-workspace) dirs=("$root") pids=() fetch_failed=()
    local name i watchdog
    while IFS=$'\t' read -r name _ _; do
        names+=("$name")
        dirs+=("$root/repos/$name")
    done < <(entries)

    for i in "${!dirs[@]}"; do
        [[ -d "${dirs[$i]}/.git" ]] || continue
        "${sgit[@]}" -C "${dirs[$i]}" fetch --quiet --no-auto-maintenance origin >/dev/null 2>&1 &
        pids[$i]=$!
    done
    # One hung fetch must not use up the hook's deadline for every other repo.
    (
        sleep "${KHE_SYNC_FETCH_LIMIT:-10}"
        kill ${pids[*]}
    ) >/dev/null 2>&1 &
    watchdog=$!
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" 2>/dev/null || fetch_failed[$i]=1
    done
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true

    if ((${#fetch_failed[@]} == ${#pids[@]})); then
        echo "  failed  all repos (no fetch worked, nothing was checked)"
        return 0
    fi

    for i in "${!dirs[@]}"; do
        if [[ ! -d "${dirs[$i]}/.git" ]]; then
            echo "  missing ${names[$i]} (run scripts/workspace.sh clone)"
        elif [[ -n "${fetch_failed[$i]:-}" ]]; then
            echo "  failed  ${names[$i]} (fetch failed, not checked)"
        else
            # The root holds the hooks that run outside the sandbox, so a pushed
            # change to it waits for a person instead of running at the next start.
            sync_repo "${names[$i]}" "${dirs[$i]}" "$( ((i == 0)) && echo report)" \
                || echo "  failed  ${names[$i]} (could not be read)"
        fi
    done
}

# Reads origin/main, so a dirty khe-meta checkout does not hide a running plan.
# Only lines of the documented shape are printed: they reach every session's
# context, and anything that can push to khe-meta can write them.
cmd_running() {
    GIT_OPTIONAL_LOCKS=0 "${sgit[@]}" -C "$root/repos/khe-meta" \
        grep -E '^\*\*Running:\*\* ' origin/main -- 'plans/*.md' 2>/dev/null \
        | sed -e 's|^origin/main:plans/||' -e 's|\.md:\*\*Running:\*\* |: |' \
        | grep -E '^[a-z0-9-]{1,80}: (laptop|agent-vm) [0-9]{4}-[0-9]{2}-[0-9]{2}( [a-z0-9-]{1,40}){1,16}$' \
        | head -n 20 || true
}

case "${1:-}" in
    clone)   cmd_clone ;;
    pull)    cmd_pull ;;
    status)  cmd_status ;;
    sync)    cmd_sync ;;
    running) cmd_running ;;
    *) echo "usage: $0 clone|pull|status|sync|running" >&2; exit 2 ;;
esac
