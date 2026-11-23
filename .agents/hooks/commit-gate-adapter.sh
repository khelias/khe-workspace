#!/usr/bin/env bash
# PreToolUse adapter for Antigravity: translates Antigravity's run_command
# payload to Claude Code's hook schema and delegates to .claude/hooks/commit-gate.sh
# so every commit/push rule, hook-bypass check, review check, PII scan and repo
# check has one source of truth.
set -uo pipefail

deny() {
    local reason="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg r "$reason" '{decision: "deny", reason: $r}'
    else
        printf '{"decision":"deny","reason":"%s"}\n' "${reason//\"/\\\"}"
    fi
    exit 0
}

command -v jq >/dev/null 2>&1 || deny "jq is required by .agents/hooks/commit-gate-adapter.sh"

root="$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd -P)" ||
    deny "could not resolve workspace root from .agents/hooks/commit-gate-adapter.sh"
gate="$root/.claude/hooks/commit-gate.sh"
[[ -x "$gate" ]] || deny "missing executable commit gate at $gate"

input="$(cat)"
[[ -n "$input" ]] || deny "empty PreToolUse payload in .agents/hooks/commit-gate-adapter.sh"

# Extract CommandLine strictly (fail closed on missing, non-string or empty CommandLine)
# and build the Claude Code payload from stdin in one jq pass to avoid ARG_MAX limits.
cmd="$(jq -r '.toolCall.args.CommandLine | select(type == "string" and length > 0)' <<<"$input" 2>/dev/null)" ||
    deny "could not parse PreToolUse payload in .agents/hooks/commit-gate-adapter.sh"
[[ -n "$cmd" ]] ||
    deny "missing or empty toolCall.args.CommandLine in .agents/hooks/commit-gate-adapter.sh"

claude_payload="$(jq --arg root "$root" '{
    tool_input: {
        command: .toolCall.args.CommandLine
    },
    cwd: (([.toolCall.args.Cwd, .cwd, .workspacePaths[0]]
        | map(select(type == "string" and length > 0))
        | first) // $root),
    transcript_path: ((.transcriptPath | select(type == "string")) // "")
}' <<<"$input" 2>/dev/null)" ||
    deny "could not build commit-gate payload in .agents/hooks/commit-gate-adapter.sh"
[[ -n "$claude_payload" ]] ||
    deny "empty commit-gate payload in .agents/hooks/commit-gate-adapter.sh"

out_file="$(mktemp)" && err_file="$(mktemp)" ||
    deny "could not create temporary files in .agents/hooks/commit-gate-adapter.sh"
trap 'rm -f -- "$out_file" "$err_file"' EXIT

CLAUDE_PROJECT_DIR="$root" /bin/bash "$gate" <<<"$claude_payload" >"$out_file" 2>"$err_file"
rc=$?

if [[ $rc -eq 0 ]]; then
    sys_msg="$(jq -r '.systemMessage | select(type == "string" and length > 0)' "$out_file" 2>/dev/null || true)"
    if [[ -n "$sys_msg" ]]; then
        jq -n --arg r "$sys_msg" '{decision: "force_ask", reason: $r}'
    else
        printf '{"decision":"allow"}\n'
    fi
    exit 0
fi

reason="$(cat "$err_file")"
[[ -n "$reason" ]] || reason="commit-gate exited with status $rc"
deny "$reason"
