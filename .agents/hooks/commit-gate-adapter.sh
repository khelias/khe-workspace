#!/usr/bin/env bash
# PreToolUse adapter for Antigravity: translates Antigravity's run_command
# payload to Claude Code's hook schema and delegates to .claude/hooks/commit-gate.sh
# so every commit/push rule, PII scan and repo check has one source of truth.
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

# Enforce the --no-verify / -n / core.hooksPath hook-bypass boundary that Claude Code
# keeps in .claude/settings.json permissions.deny, with shell-aware tokenization so
# quotes, backslash escapes and Git unique option prefixes cannot bypass it and valid
# flags (-uno, -minit, -m "--no-verify", $(echo -n x)) do not false-positive.
hook_bypass="$(awk '
function flush_tok() {
    if (has_tok) {
        ntok++
        toks[ntok] = tok
        tok = ""
        has_tok = 0
    }
}
function check_seg(    i, t, subcmd, opt, k, ch, v) {
    if (ntok == 0) return
    i = 1
    while (i <= ntok) {
        t = toks[i]
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (t == "command" || t == "exec" || t == "nohup" || t == "sudo") { i++; continue }
        if (t == "env") {
            i++
            while (i <= ntok) {
                if (toks[i] == "-u" || toks[i] == "-C" || toks[i] == "-S") { i += 2; continue }
                if (toks[i] ~ /^-/ || toks[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
                break
            }
            continue
        }
        break
    }
    if (i > ntok) return
    t = toks[i]
    if (t != "git" && t !~ /\/git$/) return
    i++
    # Global git options before the subcommand.
    while (i <= ntok) {
        t = toks[i]
        if (t == "-c") {
            i++
            if (i <= ntok && tolower(toks[i]) ~ /^core\.hookspath=/) {
                msg = "setting core.hooksPath to bypass git hooks is blocked."
                return
            }
            i++
            continue
        }
        if (substr(t, 1, 2) == "-c" && length(t) > 2) {
            v = substr(t, 3)
            if (tolower(v) ~ /^core\.hookspath=/) {
                msg = "setting core.hooksPath to bypass git hooks is blocked."
                return
            }
            i++
            continue
        }
        if (t == "-C" || t == "--git-dir" || t == "--work-tree" || t == "--namespace" ||
            t == "--config-env" || t == "--super-prefix" || t == "--list-cmds") {
            i += 2
            continue
        }
        if (substr(t, 1, 1) == "-") { i++; continue }
        break
    }
    if (i > ntok) return
    subcmd = toks[i]
    i++
    if (subcmd == "commit") {
        while (i <= ntok) {
            t = toks[i]
            if (t == "--") break
            if (t == "-m" || t == "-F" || t == "-C" || t == "-c" || t == "-t" ||
                t == "--message" || t == "--file" || t == "--reuse-message" ||
                t == "--reedit-message" || t == "--fixup" || t == "--squash" ||
                t == "--template" || t == "--author" || t == "--date" ||
                t == "--cleanup" || t == "--untracked-files" ||
                t == "--pathspec-from-file" || t == "--trailer") {
                i += 2
                continue
            }
            if (substr(t, 1, 2) == "--") {
                opt = t
                sub(/=.*/, "", opt)
                if (opt ~ /^--no-veri/) {
                    msg = "skipping git hooks with --no-verify/-n is blocked."
                    return
                }
                i++
                continue
            }
            if (substr(t, 1, 1) == "-" && length(t) >= 2) {
                for (k = 2; k <= length(t); k++) {
                    ch = substr(t, k, 1)
                    if (ch == "n") {
                        msg = "skipping git hooks with --no-verify/-n is blocked."
                        return
                    }
                    if (index("mFCct", ch) > 0) {
                        if (k == length(t)) i++
                        break
                    }
                    if (index("uS", ch) > 0) break
                }
                i++
                continue
            }
            i++
        }
    } else if (subcmd == "push") {
        while (i <= ntok) {
            t = toks[i]
            if (t == "--") break
            if (t == "-o" || t == "--push-option" || t == "--repo" ||
                t == "--receive-pack" || t == "--exec" ||
                t == "--force-with-lease" || t == "--signed") {
                i += 2
                continue
            }
            if (substr(t, 1, 2) == "--") {
                opt = t
                sub(/=.*/, "", opt)
                if (opt ~ /^--no-veri/) {
                    msg = "skipping git hooks with --no-verify is blocked."
                    return
                }
                i++
                continue
            }
            i++
        }
    }
}
function flush_seg() {
    flush_tok()
    if (msg == "") check_seg()
    ntok = 0
}
BEGIN { q = ""; tok = ""; has_tok = 0; ntok = 0; in_hd = 0; hd = ""; pending_hd = ""; msg = "" }
{
    if (msg != "") next
    line = $0
    if (in_hd) {
        t = line
        gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t == hd) in_hd = 0
        next
    }
    cont = 0
    n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "") {
            if (c == "\\") {
                if (i == n) { cont = 1; break }
                i++
                tok = tok substr(line, i, 1)
                has_tok = 1
                continue
            }
            if (c == "\047" || c == "\"") { q = c; has_tok = 1; continue }
            if (c == "#" && !has_tok) break
            if (substr(line, i, 2) == "<<") {
                flush_tok()
                rest = substr(line, i + 2)
                if (match(rest, /^-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
                    d = substr(rest, RSTART, RLENGTH)
                    sub(/^-?[ \t]*/, "", d)
                    gsub(/[\047"]/, "", d)
                    pending_hd = d
                    i += 1 + RSTART + RLENGTH - 1
                } else {
                    i++
                }
                continue
            }
            if (substr(line, i, 2) == "$(") { flush_seg(); i++; continue }
            if (index(";&|()`", c) > 0) { flush_seg(); continue }
            if (c == " " || c == "\t") { flush_tok(); continue }
            tok = tok c
            has_tok = 1
        } else if (q == "\047") {
            if (c == "\047") q = ""
            else tok = tok c
        } else {
            if (c == "\\" && i < n) {
                nc = substr(line, i + 1, 1)
                if (index("\"\\$`", nc) > 0) { i++; tok = tok nc }
                else tok = tok c
            } else if (c == "\"") {
                q = ""
            } else if (substr(line, i, 2) == "$(") {
                flush_seg()
                i++
            } else {
                tok = tok c
            }
        }
    }
    if (!cont && q == "") flush_seg()
    if (pending_hd != "") { in_hd = 1; hd = pending_hd; pending_hd = "" }
}
END {
    flush_seg()
    if (msg != "") print msg
}
' <<<"$cmd")" || deny "hook-bypass check failed in .agents/hooks/commit-gate-adapter.sh"

[[ -z "$hook_bypass" ]] || deny "commit-gate: $hook_bypass"

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
