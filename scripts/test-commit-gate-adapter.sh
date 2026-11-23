#!/usr/bin/env bash
# Tests the Antigravity commit-gate adapter (.agents/hooks/commit-gate-adapter.sh)
# end-to-end against .claude/hooks/commit-gate.sh in an isolated temporary
# workspace. Runs under macOS /bin/bash 3.2 and bash 5:
# /bin/bash scripts/test-commit-gate-adapter.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -r -f -- "$tmp"' EXIT

ws="$tmp/ws"
mkdir -p "$ws/.agents/hooks" "$ws/.claude/hooks" "$ws/repos"
cp "$root/.agents/hooks/commit-gate-adapter.sh" "$ws/.agents/hooks/commit-gate-adapter.sh"
cp "$root/.claude/hooks/commit-gate.sh" "$ws/.claude/hooks/commit-gate.sh"
cp "$root/.claude/hooks/hook-bypass.awk" "$ws/.claude/hooks/hook-bypass.awk"
cp "$root/.claude/hooks/pii-rules.toml" "$ws/.claude/hooks/pii-rules.toml"
chmod +x "$ws/.agents/hooks/commit-gate-adapter.sh" "$ws/.claude/hooks/commit-gate.sh"

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.name "Test"
    git -C "$dir" config user.email "test@example.com"
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "init"
}

init_repo "$ws"
init_repo "$ws/repos/priv-repo"
init_repo "$ws/repos/pr-repo"
init_repo "$ws/repos/rel-repo"

# Add a code file in priv-repo so review-check and commit-allow tests exercise real code commits.
printf 'echo ok\n' > "$ws/repos/priv-repo/app.sh"

cat > "$ws/repos/repos.yaml" <<'EOF'
repos:
  - name: priv-repo
    url: https://example.invalid/priv-repo.git
    private: true
    check: true
  - name: pr-repo
    url: https://example.invalid/pr-repo.git
    private: true
    pr: true
    check: true
  - name: rel-repo
    url: https://example.invalid/rel-repo.git
    private: true
    release_tag: v*
    check: true
EOF

adapter="$ws/.agents/hooks/commit-gate-adapter.sh"
fails=0

# report <name> <got> <want> <output> [<substring the output must hold>]
report() {
    if [[ "$2" != "$3" ]]; then
        printf 'FAIL %s: got %s, want %s (%s)\n' "$1" "$2" "$3" "$4"
        fails=$((fails + 1))
    elif [[ -n "${5:-}" && "$4" != *"$5"* ]]; then
        printf 'FAIL %s: output missing %s (%s)\n' "$1" "$5" "$4"
        fails=$((fails + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

check_raw() {
    local out
    out="$(printf '%s' "$3" | /bin/bash "$adapter")"
    report "$1" "$(jq -r '.decision // empty' <<<"$out" 2>/dev/null)" "$2" "$out" "${4:-}"
}

check_cmd() {
    local name="$1" want="$2" cmd="$3" cwd="${4:-$ws/repos/priv-repo}" want_substr="${5:-}" payload
    payload="$(jq -n --arg c "$cmd" --arg cwd "$cwd" --arg r "$ws" \
        '{toolCall:{name:"run_command",args:{CommandLine:$c}},cwd:$cwd,workspacePaths:[$r]}')"
    check_raw "$name" "$want" "$payload" "$want_substr"
}

# 1. Fail-closed on missing, empty or malformed payloads
check_raw "empty stdin fails closed" deny ''
check_raw "null json fails closed" deny 'null'
check_raw "empty object fails closed" deny '{}'
check_raw "schema drift commandLine fails closed" deny '{"toolCall":{"args":{"commandLine":"git commit -n"}}}'
check_raw "empty CommandLine fails closed" deny '{"toolCall":{"args":{"CommandLine":""}}}'
check_raw "malformed json fails closed" deny '{not-json'

# 2. Hook bypasses blocked by the gate's hook-bypass.awk, through the adapter
check_cmd "commit --no-verify blocked" deny 'KHE_REVIEW_SKIP=test git commit --no-verify -m x' "" "--no-verify"
check_cmd "commit quoted --no-verify blocked" deny 'KHE_REVIEW_SKIP=test git commit "--no-verify" -m x' "" "--no-verify"
check_cmd "commit quoted -n blocked" deny "KHE_REVIEW_SKIP=test git commit '-n' -m x" "" "--no-verify"
check_cmd "commit escaped --no-\\verify blocked" deny 'KHE_REVIEW_SKIP=test git commit --no-\verify -m x' "" "--no-verify"
check_cmd "commit abbreviated --no-veri blocked" deny 'KHE_REVIEW_SKIP=test git commit --no-veri -m x' "" "--no-verify"
check_cmd "commit abbreviated --no-verif blocked" deny 'KHE_REVIEW_SKIP=test git commit --no-verif -m x' "" "--no-verify"
check_cmd "push --no-verify blocked" deny 'git push --no-verify origin feat' "" "--no-verify"
check_cmd "push quoted --no-verify blocked" deny 'git push "--no-verify" origin feat' "" "--no-verify"
check_cmd "push escaped --no-\\verify blocked" deny 'git push --no-\verify origin feat' "" "--no-verify"
check_cmd "push abbreviated --no-verif blocked" deny 'git push --no-verif origin feat' "" "--no-verify"
check_cmd "subshell commit -n blocked" deny '(KHE_REVIEW_SKIP=test git commit -m x -n)' "" "--no-verify"
check_cmd "chained commit -n&& blocked" deny 'KHE_REVIEW_SKIP=test git commit -m x -n&&echo ok' "" "--no-verify"
check_cmd "subshell push --no-verify blocked" deny '(git push origin feat --no-verify)' "" "--no-verify"
check_cmd "chained push --no-verify&& blocked" deny 'git push origin feat --no-verify&&echo ok' "" "--no-verify"
check_cmd "git -c core.hooksPath blocked" deny 'KHE_REVIEW_SKIP=test git -c core.hooksPath=/dev/null commit -m x' "" "core.hooksPath"
check_cmd "git -ccore.hooksPath blocked" deny 'KHE_REVIEW_SKIP=test git -ccore.hooksPath=/dev/null commit -m x' "" "core.hooksPath"
check_cmd "git --git-dir commit --no-verify blocked" deny 'KHE_REVIEW_SKIP=test git --git-dir .git commit --no-verify -m x' "" "--no-verify"
check_cmd "quoted heredoc does not hide --no-verify" deny $'echo "x <<EOF"\nKHE_REVIEW_SKIP=test git commit --no-verify -m x' "" "--no-verify"
# shellcheck disable=SC2016
check_cmd "--no-verify after a quoted substitution blocked" deny 'KHE_REVIEW_SKIP=test git commit -m "$(echo x)" --no-verify' "" "--no-verify"
# shellcheck disable=SC2016
check_cmd "-n after a backtick substitution blocked" deny 'KHE_REVIEW_SKIP=test git commit -m "a `date` b" -n' "" "--no-verify"
check_cmd "commit -n inside if blocked" deny 'if KHE_REVIEW_SKIP=test git commit -n -m x; then :; fi' "" "--no-verify"
check_cmd "--untracked-files does not swallow -n" deny 'KHE_REVIEW_SKIP=test git commit --untracked-files -n -m x' "" "--no-verify"
check_cmd "--signed does not swallow --no-verify" deny 'git push --signed --no-verify origin feat' "" "--no-verify"
check_cmd "git --config-env core.hooksPath blocked" deny 'KHE_REVIEW_SKIP=test git --config-env core.hooksPath=H commit -m x' "" "core.hooksPath"
check_cmd "GIT_CONFIG_COUNT env before commit blocked" deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null KHE_REVIEW_SKIP=test git commit -m x' "" "GIT_CONFIG_"
check_cmd "exported GIT_CONFIG_PARAMETERS before commit blocked" deny $'export GIT_CONFIG_PARAMETERS=x\nKHE_REVIEW_SKIP=test git commit -m x' "" "GIT_CONFIG_"
check_cmd "git config core.hooksPath blocked" deny 'git config core.hooksPath /dev/null' "" "core.hooksPath"
check_cmd "git config --get core.hooksPath allowed" allow 'git config --get core.hooksPath'
check_cmd "sudo -u does not hide commit -n" deny 'sudo -u me git commit -n -m x' "" "--no-verify"
check_cmd "heredoc delimiter with a dash read whole" deny $'cat <<END-OF\nx\nEND-OF\nKHE_REVIEW_SKIP=test git commit --no-verify -m x' "" "--no-verify"
# shellcheck disable=SC2016
check_cmd "arithmetic shift is not a heredoc" deny $'echo $((a<<b))\nKHE_REVIEW_SKIP=test git commit --no-verify -m x' "" "--no-verify"
check_cmd "here-string is not a heredoc" deny $'cat <<<EOF\nKHE_REVIEW_SKIP=test git commit --no-verify -m x' "" "--no-verify"
check_cmd "timeout wrapper does not hide --no-verify" deny 'KHE_REVIEW_SKIP=test timeout 600 git commit --no-verify -m x' "" "--no-verify"
check_cmd "nice -n wrapper does not hide -n" deny 'KHE_REVIEW_SKIP=test nice -n 5 git commit -n -m x' "" "--no-verify"
check_cmd "xargs wrapper does not hide push --no-verify" deny 'echo feat | xargs git push --no-verify origin' "" "--no-verify"
check_cmd "/usr/bin/env wrapper does not hide -n" deny 'KHE_REVIEW_SKIP=test /usr/bin/env git commit -n -m x' "" "--no-verify"
check_cmd "ANSI-C quoted --no-verify blocked" deny "KHE_REVIEW_SKIP=test git commit \$'--no-verify' -m x" "" "--no-verify"
check_cmd "brace-expanded --no-verify blocked" deny 'KHE_REVIEW_SKIP=test git commit {--no-verify,} -m x' "" "--no-verify"
check_cmd "-c include.path blocked" deny 'KHE_REVIEW_SKIP=test git -c include.path=/tmp/x commit -m x' "" "included config"
check_cmd "GIT_CONFIG_GLOBAL before commit blocked" deny 'GIT_CONFIG_GLOBAL=/tmp/x KHE_REVIEW_SKIP=test git commit -m x' "" "GIT_CONFIG_"
check_cmd "commit -n inside a function body blocked" deny 'f() { KHE_REVIEW_SKIP=test git commit -n -m x; }; f' "" "--no-verify"

# 3. Valid commands do not false-positive
check_cmd "commit -uno allowed" allow 'KHE_REVIEW_SKIP=test git commit -uno -m test'
check_cmd "commit -minit allowed" allow 'KHE_REVIEW_SKIP=test git commit -minit'
check_cmd "commit -Cnext allowed" allow 'KHE_REVIEW_SKIP=test git commit -Cnext -m x'
check_cmd "commit -Fnotes allowed" allow 'KHE_REVIEW_SKIP=test git commit -Fnotes'
check_cmd "commit message mentioning --no-verify allowed" allow 'KHE_REVIEW_SKIP=test git commit -m "--no-verify"'
# shellcheck disable=SC2016
check_cmd "commit with echo -n subshell allowed" allow 'KHE_REVIEW_SKIP=test git commit -m foo $(echo -n x)'
check_cmd "commit -Ssigningkey allowed" allow 'KHE_REVIEW_SKIP=test git commit -Ssigningkey -m x'
check_cmd "commit path -- -n allowed" allow 'KHE_REVIEW_SKIP=test git commit -m x -- -n'
check_cmd "push -n dry-run allowed" allow 'git push -n origin feat'
check_cmd "git status allowed" allow 'git status --short'
check_cmd "rg --no-verify allowed" allow 'rg --no-verify .'

# 4. Empty-string args.Cwd falls back to .cwd
cwd_payload="$(jq -n --arg c 'git push origin main' --arg cwd "$ws/repos/pr-repo" --arg r "$ws" \
    '{toolCall:{name:"run_command",args:{CommandLine:$c,Cwd:""}},cwd:$cwd,workspacePaths:[$r]}')"
check_raw "empty args.Cwd falls back to .cwd" deny "$cwd_payload" "repos/pr-repo"

# 5. Delegation to real commit-gate.sh
check_cmd "git add -A blocked" deny 'git add -A' "" "git add -A"
check_cmd "git commit -a blocked" deny 'KHE_REVIEW_SKIP=test git commit -a -m x' "" "git commit -a"
check_cmd "git push --force blocked" deny 'git push --force origin main' "" "rewrites the remote"
check_cmd "pr: true push to main blocked" deny 'git -C repos/pr-repo push origin main' "$ws" "repos/pr-repo"
check_cmd "release_tag push blocked" deny 'git -C repos/rel-repo push origin v1.0.0' "$ws" "repos/rel-repo"
check_cmd "gh pr merge --admin blocked" deny 'gh pr merge 1 --admin' "$ws" "--admin"
check_cmd "code commit without KHE_REVIEW_SKIP blocked" deny 'git commit -m test' "$ws/repos/priv-repo" "KHE_REVIEW_SKIP"
check_cmd "KHE_PR_SKIP forwarded as force_ask" force_ask \
    'KHE_PR_SKIP="emergency" KHE_REVIEW_SKIP="test" git -C repos/pr-repo commit -m test' \
    "$ws" "KHE_PR_SKIP"

# 6. Antigravity review evidence: a structured invoke_subagent of code-reviewer
# counts, the same name in text or another tool's arguments does not. The
# fixture lines are real Antigravity steps with their prompts and values redacted.
reviewed="$tmp/reviewed.jsonl"
unreviewed="$tmp/unreviewed.jsonl"
cat > "$reviewed" <<'EOF'
{"type":"USER_INPUT","source":"USER","status":"DONE","step_index":0,"content":"change app.sh"}
{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":1,"model":"gemini","tool_calls":[{"name":"invoke_subagent","args":{"Model":"\"inherit\"","Prompt":"\"Review the diff\"","Role":"\"Review app.sh\"","TypeName":"\"code-reviewer\""}}]}
{"type":"PLANNER_RESPONSE","source":"MODEL","status":"RUN
EOF
cat > "$unreviewed" <<'EOF'
{"type":"USER_INPUT","source":"USER","status":"DONE","step_index":0,"content":"run the code-reviewer subagent, then commit"}
{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":1,"model":"gemini","tool_calls":[{"name":"run_command","args":{"CommandLine":"echo code-reviewer","TypeName":"\"code-reviewer\""}},{"name":"invoke_subagent","args":{"Prompt":"\"code-reviewer\"","TypeName":"\"research\""}}]}
EOF
transcript_payload() {
    jq -n --arg c "$1" --arg cwd "$ws/repos/priv-repo" --arg r "$ws" --arg t "$2" \
        '{toolCall:{name:"run_command",args:{CommandLine:$c}},cwd:$cwd,workspacePaths:[$r],transcriptPath:$t}'
}
check_raw "Antigravity code-reviewer subagent counts as review" allow "$(transcript_payload 'git commit -m test' "$reviewed")"
check_raw "code-reviewer only in text or other tools does not count" deny \
    "$(transcript_payload 'git commit -m test' "$unreviewed")" "code-reviewer subagent in Antigravity"

# 7. Claude Code payloads straight to commit-gate.sh
gate_cmd() {
    local err
    err="$(jq -n --arg c "$3" --arg cwd "$ws/repos/priv-repo" '{tool_input:{command:$c},cwd:$cwd,transcript_path:""}' |
        CLAUDE_PROJECT_DIR="$ws" /bin/bash "${4:-$ws/.claude/hooks/commit-gate.sh}" 2>&1 >/dev/null)"
    report "$1" "exit $?" "exit $2" "$err" "${5:-}"
}
gate_cmd "Claude commit --no-verify blocked" 2 'KHE_REVIEW_SKIP=test git commit -m x --no-verify' "" "skips git hooks"
# shellcheck disable=SC2016
gate_cmd "Claude heredoc message quoting bypass flags passes" 0 'KHE_REVIEW_SKIP=test git commit -m "$(cat <<'"'"'EOF'"'"'
Block bypasses in the gate

An odd " here, and the body quotes `git commit -n` and
git push --no-verify, which the hook-bypass check must not read.
EOF
)"'
mkdir -p "$tmp/noawk"
cp "$ws/.claude/hooks/commit-gate.sh" "$tmp/noawk/commit-gate.sh"
gate_cmd "missing hook-bypass.awk: non-git call passes" 0 'ls -la' "$tmp/noawk/commit-gate.sh"
gate_cmd "missing hook-bypass.awk: git status passes" 0 'git status' "$tmp/noawk/commit-gate.sh"
gate_cmd "missing hook-bypass.awk: commit blocked" 2 'KHE_REVIEW_SKIP=test git commit -m x' "$tmp/noawk/commit-gate.sh" "missing or failing"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
