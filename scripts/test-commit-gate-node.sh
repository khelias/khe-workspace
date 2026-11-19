#!/usr/bin/env bash
# Tests the commit gate's choice of Node for a repo's check against a fake nvm
# tree. Runs under macOS /bin/bash 3.2 and bash 5: /bin/bash scripts/test-commit-gate-node.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -r -f -- "$tmp"' EXIT
sed -n '/^node_bin_dir=unset/,/^}/p' "$root/.claude/hooks/commit-gate.sh" > "$tmp/fn.sh"
[[ -s "$tmp/fn.sh" ]] || { echo "resolve_nvm_default not found in the gate"; exit 1; }

nvm="$tmp/nvm"
for v in 11.15.0 22.9.0 22.15.0 22.22.0 24.13.0 26.13.1 240.1.0; do
    mkdir -p "$nvm/versions/node/v$v/bin"
    printf '#!/bin/sh\n' > "$nvm/versions/node/v$v/bin/node"
    chmod +x "$nvm/versions/node/v$v/bin/node"
done
mkdir -p "$nvm/versions/node/v25.0.0/bin" "$nvm/alias/lts/broken"
printf 'v26.13.1' > "$nvm/alias/lts/lithium"
printf 'lts/lithium' > "$nvm/alias/lts/*"

fails=0
pick() { NVM_DIR="$nvm" bash -c ". '$tmp/fn.sh'; resolve_nvm_default; resolve_nvm_default; printf '%s' \"\$node_bin_dir\"" 2>&1; }
case_() {
    local name="$1" alias="$2" want="$3" got
    if [[ "$alias" == '<none>' ]]; then rm -f "$nvm/alias/default"; else printf '%s' "$alias" > "$nvm/alias/default"; fi
    got="$(pick)"
    got="${got#"$nvm/versions/node/"}"
    if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: got '$got', want '$want'"; fails=$((fails + 1)); fi
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
printf '24\n' > "$nvm/alias/default"
got="$(pick)"; [[ "$got" == "$nvm/versions/node/v24.13.0/bin" ]] && echo "ok   a trailing newline" || { echo "FAIL a trailing newline: $got"; fails=$((fails + 1)); }
got="$(NVM_DIR="$tmp/none" HOME="$tmp/none" bash -c ". '$tmp/fn.sh'; resolve_nvm_default; printf '%s' \"\$node_bin_dir\"" 2>&1)"
[[ -z "$got" ]] && echo "ok   no nvm at all" || { echo "FAIL no nvm at all: $got"; fails=$((fails + 1)); }

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
