#!/bin/bash
# StopFailure: an API error (the usage limit among them) ended a turn. Append
# "<UTC time> <session id> <error> <transcript path>" to the main checkout's
# .claude/state/stop-failures.log, so `next` can say which sessions were cut.
# The trim to 200 lines waits for 400, so its unlocked rewrite is rare.
# Never blocks: always exits 0.

common="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
main="$(dirname "$common")"
state="$main/.claude/state"
log="$state/stop-failures.log"

fields="$(jq -r 'select(.session_id != null) | [.session_id, .error, .transcript_path]
    | map(tostring | gsub("[[:cntrl:][:space:]]+"; "_")) | join(" ")' 2>/dev/null)" || exit 0
[ -n "$fields" ] || exit 0

mkdir -p "$state" 2>/dev/null || exit 0
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $fields" >>"$log" 2>/dev/null || exit 0
if [ "$(wc -l <"$log")" -gt 400 ]; then
    tmp="$(mktemp "$state/stop-failures.XXXXXX")" || exit 0
    tail -n 200 "$log" >"$tmp" && mv "$tmp" "$log" || rm -f "$tmp"
fi
exit 0
