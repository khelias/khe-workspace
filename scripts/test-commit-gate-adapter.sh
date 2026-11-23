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

check_raw() {
    local name="$1" want="$2" payload="$3" want_substr="${4:-}" out got
    out="$(printf '%s' "$payload" | /bin/bash "$adapter")"
    got="$(jq -r '.decision // empty' <<<"$out" 2>/dev/null)"
    if [[ "$got" != "$want" ]]; then
        printf 'FAIL %s: got decision=%s, want %s (%s)\n' "$name" "$got" "$want" "$out"
        fails=$((fails + 1))
        return
    fi
    if [[ -n "$want_substr" && "$out" != *"$want_substr"* ]]; then
        printf 'FAIL %s: output missing %s (%s)\n' "$name" "$want_substr" "$out"
        fails=$((fails + 1))
        return
    fi
    printf 'ok   %s\n' "$name"
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

# 2. Hook bypasses blocked by adapter
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

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
