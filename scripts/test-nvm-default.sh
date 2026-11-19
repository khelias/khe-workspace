#!/usr/bin/env bash
# Tests the choice of nvm's default Node and Homebrew's bin
# (.claude/hooks/nvm-default.sh) and the node-path hook against a fake nvm
# tree and Homebrew prefix. Runs under macOS /bin/bash 3.2 and bash 5:
# /bin/bash scripts/test-nvm-default.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$root/.claude/hooks/nvm-default.sh"
hook="$root/.claude/hooks/node-path.sh"
tmp="$(mktemp -d)"
trap 'rm -r -f -- "$tmp"' EXIT

nvm="$tmp/nvm"
versions="$nvm/versions/node"
for v in 11.15.0 22.9.0 22.15.0 22.22.0 24.13.0 26.13.1 240.1.0; do
    mkdir -p "$versions/v$v/bin"
    printf '#!/bin/sh\n' > "$versions/v$v/bin/node"
    chmod +x "$versions/v$v/bin/node"
done
mkdir -p "$versions/v25.0.0/bin" "$nvm/alias/lts/broken"
printf 'v26.13.1' > "$nvm/alias/lts/lithium"
printf 'lts/lithium' > "$nvm/alias/lts/*"

fails=0
result() {
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
pick() { NVM_DIR="$1" bash -c ". '$lib'; resolve_nvm_default; resolve_nvm_default; printf '%s' \"\$node_bin_dir\"" 2>&1; }
case_() {
    if [[ "$2" == '<none>' ]]; then rm -f "$nvm/alias/default"; else printf '%s' "$2" > "$nvm/alias/default"; fi
    local got
    got="$(pick "$nvm")"
    result "$1" "${got#"$versions/"}" "$3"
}

case_ "a major picks its newest minor" 22 v22.22.0/bin
case_ "24 does not match 240" 24 v24.13.0/bin
case_ "a full version with v" v22.15.0 v22.15.0/bin
case_ "a major and minor" 22.9 v22.9.0/bin
case_ "an lts chain" 'lts/*' v26.13.1/bin
case_ "node is the newest installed" node v240.1.0/bin
case_ "stable is the newest installed" stable v240.1.0/bin
case_ "a version without a node binary" 25 ""
case_ "system leaves PATH alone" system ""
case_ "a version not installed" 18 ""
case_ "an alias that is a command" '22; touch x' ""
case_ "an alias that is a directory" lts/broken ""
case_ "no default alias" '<none>' ""
case_ "a trailing newline" $'24\n' v24.13.0/bin
result "no nvm at all" "$(pick "$tmp/none")" ""

brew="$tmp/brew"
mkdir -p "$brew/bin" "$tmp/nobrew/bin"
printf '#!/bin/sh\n' > "$brew/bin/brew"
chmod +x "$brew/bin/brew"
export HOMEBREW_PREFIX="$tmp/nobrew"
prefix() { NVM_DIR="$1" HOMEBREW_PREFIX="$2" bash -c ". '$lib'; resolve_tool_path; printf '%s' \"\$tool_path_prefix\"" 2>&1; }
printf '24' > "$nvm/alias/default"
result "the prefix is Node, then Homebrew" "$(prefix "$nvm" "$brew")" "$versions/v24.13.0/bin:$brew/bin"
result "Homebrew alone without nvm" "$(prefix "$tmp/none" "$brew")" "$brew/bin"
result "a bin folder without brew is not Homebrew" "$(prefix "$tmp/none" "$tmp/nobrew")" ""
result "a relative Homebrew prefix is ignored" "$(prefix "$tmp/none" "brew")" ""

env_file="$tmp/env"
old="$versions/v11.15.0/bin:/usr/bin:/bin"
: > "$env_file"
CLAUDE_ENV_FILE="$env_file" NVM_DIR="$nvm" HOMEBREW_PREFIX="$brew" bash "$hook"
result "node-path puts Node and Homebrew first, once" \
    "$(PATH="$old" bash -c ". '$env_file'; . '$env_file'; printf '%s' \"\$PATH\"")" "$versions/v24.13.0/bin:$brew/bin:$old"
: > "$env_file"
CLAUDE_ENV_FILE="$env_file" NVM_DIR="$nvm" bash "$hook"
result "node-path puts the default first, once" \
    "$(PATH="$old" bash -c ". '$env_file'; . '$env_file'; printf '%s' \"\$PATH\"")" "$versions/v24.13.0/bin:$old"
: > "$env_file"
CLAUDE_ENV_FILE="$env_file" NVM_DIR="$tmp/none" bash "$hook"
result "node-path without nvm writes nothing" "$? $(wc -c < "$env_file" | tr -d ' ')" "0 0"
CLAUDE_ENV_FILE="" NVM_DIR="$nvm" bash "$hook"
result "node-path without an env file exits 0" "$?" 0

# A helper that is missing, or stops part way, must leave the env file empty.
mkdir -p "$tmp/broken"
cp "$hook" "$tmp/broken/node-path.sh"
: > "$env_file"
CLAUDE_ENV_FILE="$env_file" NVM_DIR="$nvm" bash "$tmp/broken/node-path.sh"
result "node-path without its helper writes nothing" "$? $(wc -c < "$env_file" | tr -d ' ')" "0 0"
printf 'node_bin_dir=unset\nif then\n' > "$tmp/broken/nvm-default.sh"
CLAUDE_ENV_FILE="$env_file" NVM_DIR="$nvm" bash "$tmp/broken/node-path.sh" 2>/dev/null
result "node-path with a broken helper writes nothing" "$? $(wc -c < "$env_file" | tr -d ' ')" "0 0"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
