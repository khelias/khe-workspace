#!/bin/bash
# Fixture test for `scripts/agent-metrics.sh --json`: three plans with Caught
# lines and no shas in a temporary folder, so neither git history nor GitHub
# is read. Needs jq, and gh on PATH (the script checks for it).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() { echo "ok   $1"; }
fail() {
    echo "FAIL $1"
    [[ -z "${2:-}" ]] || echo "     got: $2"
    failures=$((failures + 1))
}
expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "$2"; fi; }

plans="$work/fixture-plans"
mkdir "$plans"
printf '%s\n' '# Fixture alpha' '' '**Status:** done' \
    '**Caught:** plan review 6 (1 dropped); plan check -; code review 3 (2 dropped); security review -; operator 1; push unchanged.' \
    >"$plans/fixture-alpha.md"
printf '%s\n' '# Fixture beta' '' '**Status:** done' \
    '**Caught:** plan review 4 (0 dropped); plan check 2; code review 5; security review 1 (1 dropped); operator -; push changed.' \
    >"$plans/fixture-beta.md"
printf '%s\n' '# Fixture gamma' '' '**Status:** running' \
    '**Caught:** plan review 3; plan check pending; code review pending; security review pending; operator pending; push pending.' \
    >"$plans/fixture-gamma.md"

out="$(bash "$here/agent-metrics.sh" --plans "$plans" --json)"
rc=$?
expect_eq "exits 0" "$rc" 0
if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    fail "prints one JSON object" "$out"
    exit 1
fi

q() { jq -c "$1" <<<"$out"; }
# The exact values below also fix each nested object's keys and their order.
expect_eq "top-level keys" "$(q 'keys_unsorted')" \
    '["since","until","plans","planReview","planCheck","codeReview","securityReview","operator","push","pushedPlans","revertedPlans","planToPush"]'
expect_eq "until is today" "$(jq -r .until <<<"$out")" "$(date +%Y-%m-%d)"

expect_eq "plans" "$(q '.plans')" 3
expect_eq "plan review" "$(q '.planReview')" '{"acted":13,"dropped":1,"notRun":0,"pending":0}'
expect_eq "plan check" "$(q '.planCheck')" '{"acted":2,"dropped":0,"notRun":1,"pending":1}'
expect_eq "code review" "$(q '.codeReview')" '{"acted":8,"dropped":2,"notRun":0,"pending":1}'
expect_eq "security review" "$(q '.securityReview')" '{"acted":1,"dropped":1,"notRun":1,"pending":1}'
expect_eq "operator" "$(q '.operator')" '{"acted":1,"notRun":1,"pending":1}'
expect_eq "push" "$(q '.push')" '{"unchanged":1,"changed":1,"discarded":0,"pending":1}'
expect_eq "no plan pushed without shas" "$(q '[.pushedPlans, .revertedPlans]')" '[0,0]'
expect_eq "plan to push with no count" "$(q '.planToPush')" '{"count":0,"medianMinutes":0}'

for name in fixture-alpha fixture-beta fixture-gamma fixture-plans; do
    if [[ "$out" == *"$name"* ]]; then fail "no $name in the output" "$out"; else pass "no $name in the output"; fi
done

[[ "$failures" -eq 0 ]] || { echo "$failures failed"; exit 1; }
echo "all passed"
