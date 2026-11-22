#!/usr/bin/env bash
# SessionStart hook for Antigravity: fast-forward clean main checkouts under
# repos/ via scripts/workspace.sh sync and report any repos needing attention
# or plans marked **Running:**. Never blocks a session: always exits 0.
set -uo pipefail

deadline_seconds=15

empty_ok() {
    printf '{}\n'
    exit 0
}

command -v jq >/dev/null 2>&1 || empty_ok
[[ -t 0 ]] || cat >/dev/null 2>&1 || true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || empty_ok
common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || empty_ok
main="$(dirname "$common")"
[[ -x "$main/scripts/workspace.sh" ]] || empty_ok

output="$(mktemp -d)" || empty_ok
repos_pid=""
cleanup() {
    if [[ -n "$repos_pid" ]] && kill -0 "$repos_pid" 2>/dev/null; then
        kill -TERM "$repos_pid" 2>/dev/null || true
    fi
    rm -rf -- "$output"
}
trap cleanup EXIT
trap 'cleanup; exit 0' TERM INT HUP

"$main/scripts/workspace.sh" sync >"$output/repos" 2>&1 </dev/null &
repos_pid=$!

started=$SECONDS
while kill -0 "$repos_pid" 2>/dev/null && [ $((SECONDS - started)) -lt "$deadline_seconds" ]; do
    sleep 0.2
done

timed_out=
if kill -0 "$repos_pid" 2>/dev/null; then
    # TERM lets sync finish a merge in progress and release its lock.
    {
        kill -TERM "$repos_pid"
        sleep 1
        kill -KILL "$repos_pid"
    } 2>/dev/null
    timed_out="Session sync stopped at its ${deadline_seconds}-second limit; the lines below are what finished."
fi
wait "$repos_pid" 2>/dev/null || true

msg=""
if [[ -n "$timed_out" ]]; then
    msg="$timed_out"
fi

repos_out="$(cat "$output/repos" 2>/dev/null || true)"
if [[ -n "$repos_out" ]]; then
    msg="${msg:+$msg$'\n'}$repos_out"
fi

plans="$("$main/scripts/workspace.sh" running 2>/dev/null || true)"
if [[ -n "$plans" ]]; then
    plans_block="Plans running now (ask the operator before changing a repo named here):"$'\n'"$(printf '%s\n' "$plans" | sed 's/^/  /')"
    msg="${msg:+$msg$'\n'}$plans_block"
fi

if [[ -z "$msg" ]]; then
    empty_ok
fi

jq -n --arg m "$msg" '{injectSteps: [{systemMessage: {systemMessage: $m}}]}' || empty_ok
exit 0
