#!/usr/bin/env bash
# PreToolUse hook: before Claude runs `git commit` in the workspace root or one
# of the workspace repos, require a /code-review in this session when the
# commit may include code (anything but md, txt, pdf and images), then scan
# what the commit adds for personal-data patterns (.claude/hooks/pii-rules.toml,
# skipped for repos marked `private: true` in repos/repos.yaml), then run that
# repo's `check:` command. Any of them failing blocks the commit (exit 2,
# output to stderr), as does a commit whose repo it cannot resolve or that is
# an unlisted repo inside the workspace. The review is a `Skill` call to
# code-review in the session transcript; prefixing the commit with
# KHE_REVIEW_SKIP="<reason>" skips only that check. It also refuses
# `git add -A/./-u` and `git commit -a` in any call. Other Bash calls pass
# through untouched, so a passing commit costs no tokens. The hook is
# registered with onFailure "block", so an error in this script blocks every
# Bash call: it runs under /bin/bash 3.2.
set -uo pipefail

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
root="${CLAUDE_PROJECT_DIR:-$cwd}"
git_core='git(([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*)[[:space:]]+'
git_re="(^|[;&|([:space:]/])${git_core}"

# Matching runs on one line with heredoc bodies dropped and every quoted string
# that holds a space replaced by Q: a message or PR body that mentions a git
# command must neither trigger nor block anything. Quoted paths keep their text.
scan="$(awk '
    skip { t = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if (t == delim) skip = 0; next }
    { printf "%s;", $0 }
    match($0, /(^|[^<])<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/) {
        delim = substr($0, RSTART, RLENGTH); sub(/^[^<]?<<-?[[:space:]]*["\047]?/, "", delim); skip = 1
    }' <<<"$cmd" | awk '{
    out = ""; q = ""; tok = ""
    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q == "") { if (c == "\"" || c == "\047") { q = c; tok = c } else out = out c; continue }
        tok = tok c
        if (q == "\"" && c == "\\") { i++; tok = tok substr($0, i, 1); continue }
        if (c == q) { out = out (tok ~ /[[:space:];]/ ? "Q" : tok); q = "" }
    }
    print out (q == "" ? "" : "Q")
}')"

fail() { echo "commit-gate: $1; commit blocked." >&2; exit 2; }

# Parallel sessions share each repo's working tree, so staging everything
# sweeps another session's files into this commit. Stage by path.
sweep_add="${git_re}(add|stage)[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*[Au][A-Za-z]*|--all|--update|\.|:/|\"\.\"|'\.')([[:space:]]|;|\$)"
sweep_commit="${git_re}commit[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*a[A-Za-z]*|--all)([[:space:]]|;|\$)"
if [[ "$scan" =~ $sweep_add || "$scan" =~ $sweep_commit ]]; then
    echo "commit-gate: 'git add -A/./-u' and 'git commit -a' stage files other sessions may be editing; blocked. Stage the files you changed by path." >&2
    exit 2
fi

commit_re="${git_re}commit([[:space:]]|;|\$)"
[[ "$scan" =~ $commit_re ]] || exit 0

# git@host:owner/repo, ssh://git@host/owner/repo.git and https://host/owner/repo
# all become host/owner/repo.
norm_url() {
    local u="${1%/}"
    u="${u%.git}"; u="${u#*://}"; u="${u#*@}"; u="${u/://}"
    printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

unquote() { local v="$1"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s' "$v"; }

# The hook runs before the command, so a file force-added in the same call is
# still ignored and invisible to the scan below.
add_re="${git_re}add[[:space:]]([^;&|]*[[:space:]])?(-f|--force|-[A-Za-z]*f[A-Za-z]*)([[:space:]]|;|\$)"
[[ "$scan" =~ $add_re ]] &&
    fail "a same-call 'git add --force' cannot be scanned. Run the add as its own command first, then commit"

# Each commit's directory: its `git -C <dir>`, else the last `cd <dir>` before
# it, else cwd. A command may commit in several repos; each one is gated.
resolve() {
    local d
    d="$(unquote "$1")"
    [[ "$d" == "~" || "$d" == "~/"* ]] && d="$HOME${d#"~"}"
    [[ "$d" = /* ]] || d="$2/$d"
    printf '%s' "$d"
}
cd_re='(^|[;&|([:space:]])cd[[:space:]]+([^[:space:];&|)]+)'
dir="$cwd"
dirs=()
rest="$scan"
while [[ "$rest" =~ $commit_re ]]; do
    m="${BASH_REMATCH[0]}" flags="${BASH_REMATCH[2]}"
    pre="${rest%%"$m"*}"
    while [[ "$pre" =~ $cd_re ]]; do
        dir="$(resolve "${BASH_REMATCH[2]}" "$dir")"
        pre="${pre#*"${BASH_REMATCH[0]}"}"
    done
    d="$dir"
    [[ "$flags" =~ -C[[:space:]]+([^[:space:]]+) ]] && d="$(resolve "${BASH_REMATCH[1]}" "$dir")"
    dirs+=("$d")
    rest="${rest#*"$m"}"
done

# A deliberate review skip must prefix the commit itself; on $scan a message or
# heredoc that mentions the variable cannot trigger it. An empty value does not
# skip. The skip covers every repo the call commits in.
review_skip=
skip_re="(^|[;&|(])[[:space:]]*KHE_REVIEW_SKIP=([^[:space:];&|]+)[[:space:]]+([^[:space:];&|]*/)?${git_core}commit([[:space:]]|;|\$)"
rest="$scan"
while [[ "$rest" =~ $skip_re ]]; do
    v="${BASH_REMATCH[2]}"
    [[ "$v" == '""' || "$v" == "''" ]] || { review_skip=1; break; }
    rest="${rest#*"${BASH_REMATCH[0]}"}"
done
transcript="$(jq -r '.transcript_path // empty' <<<"$input")"
review=

# Prints yes or no for a code-review Skill call in the main transcript and its
# subagents' files, or nothing when no line parses. Lines are parsed one by one
# because the last one may still be half written, and streamed with an early
# stop because a transcript can run to tens of megabytes.
review_state() {
    local f files
    [[ -n "$transcript" && -f "$transcript" ]] || return 0
    files=("$transcript")
    for f in "${transcript%.jsonl}"/subagents/*.jsonl; do
        [[ -f "$f" ]] && files+=("$f")
    done
    jq -R -n -r '
        def review: .type == "assistant" and
            any(.message | objects | .content | arrays | .[] | objects;
                .type == "tool_use" and .name == "Skill" and
                (.input | objects | .skill | strings | test("(^|:)code-review$")));
        label $out | foreach ((inputs | fromjson? | objects), "EOF") as $o ("none";
            if $o == "EOF" then . else "no" end;
            if $o == "EOF" then select(. != "none")
            elif ($o | review) then ("yes", break $out)
            else empty end)' "${files[@]}" 2>/dev/null
}

tmp_root="$(mktemp -d)" && [[ -d "$tmp_root" ]] || fail "no temporary directory for the personal-data scan"
trap 'rm -r -f -- "$tmp_root"' EXIT

gate() {
    local dir="$1"
    # A worktree's common dir is still repos/<name>/.git, which names the repo;
    # the root repo's common dir is the same from any of its worktrees.
    # A directory the hook cannot resolve (a shell variable, a path that does not
    # exist, a cd it cannot follow) must not pass unchecked.
    common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
        top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" ||
        fail "cannot tell which repo '$dir' is. Commit one repo per command, as 'git -C <absolute path> commit'"
    root_common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    # A desktop worktree of the root has no clones in its repos/, so a repo
    # worktree made from it keeps its common dir in the main checkout's repos/.
    local ws=("$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")") w u r p
    [[ "$root_common" == */.git ]] && ws+=("${root_common%/.git}")

    # Name the repo whose common dir is $1, only if repos.yaml lists it.
    by_common() {
        local w n
        [[ -n "$root_common" && "$1" == "$root_common" ]] && { printf 'khe'; return; }
        for w in "${ws[@]}"; do
            n="${1#"$w"/repos/}"; n="${n%/.git}"
            [[ "$1" == "$w/repos/$n/.git" && "$n" != */* ]] || continue
            awk -v want="$n" '/^[[:space:]]*- name:/ { sub(/.*name:[[:space:]]*/, ""); if ($0 == want) f = 1 }
                END { exit !f }' "$root/repos/repos.yaml" 2>/dev/null && printf '%s' "$n"
            return
        done
    }
    by_url() {
        local want n yurl
        want="$(norm_url "$1")"
        while IFS=$'\t' read -r n yurl; do
            [[ "$(norm_url "$yurl")" == "$want" ]] && { printf '%s' "$n"; return; }
        done < <(awk '
            /^[[:space:]]*- name:/ { sub(/.*name:[[:space:]]*/, ""); cur = $0; next }
            /^[[:space:]]*url:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print cur "\t" $0 }
        ' "$root/repos/repos.yaml" 2>/dev/null)
    }

    name="$(by_common "$common")"
    # A clone elsewhere is still that repo if a remote is its URL or its checkout.
    if [[ -z "$name" ]]; then
        while read -r u; do
            u="${u#file://}"
            # git stores a hand-added relative remote as typed, relative to the repo.
            p="$u"; [[ "$p" = /* ]] || p="$top/$p"
            if [[ -d "$p" ]]; then
                r="$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
                    name="$(by_common "$r")"
            else
                name="$(by_url "$u")"
            fi
            [[ -n "$name" ]] && break
        done < <(git -C "$top" remote -v 2>/dev/null | awk '{ print $2 }' | sort -u)
    fi
    # Anything else inside the workspace (a nested repo, one missing from
    # repos.yaml) fails closed; repos elsewhere, such as scratch repos, pass.
    if [[ -z "$name" ]]; then
        for w in "${ws[@]}"; do
            [[ "$top/" == "$w/"* || "$common" == "$w/"* ]] &&
                fail "'$top' is inside the workspace but is neither the root nor a repo listed in repos/repos.yaml"
        done
        return 0
    fi
    label="repos/$name"
    [[ "$name" == khe ]] && label="the workspace root"

    yaml_key() {
        awk -v want="$name" -v key="$1" '
            /^[[:space:]]*- name:/ { sub(/.*name:[[:space:]]*/, ""); cur = $0; next }
            $0 ~ "^[[:space:]]*" key ":" && cur == want { sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
        ' "$root/repos/repos.yaml" 2>/dev/null
    }

    block() {
        {
            echo "commit-gate: personal data in what this commit adds to $label; commit blocked."
            printf '%s\n' "$@"
            echo "Remove it, or if it is a false positive add an allowlist entry with a reason"
            echo "to .claude/hooks/pii-rules.toml. Values are redacted here on purpose."
        } >&2
        exit 2
    }

    tmp="$(mktemp -d "$tmp_root/gate.XXXXXX")" || fail "no temporary directory for $label"
    g() { git -C "$top" -c core.quotePath=false "$@"; }
    base=HEAD
    g rev-parse -q --verify HEAD >/dev/null || base=4b825dc642cb6eb9a060e54bf8d69288fbee4904

    # The hook runs before any same-call `git add`, so staged, unstaged and
    # untracked files may all end up in this commit. A scanned repo's diffs are
    # taken right beside its name lists, which must list the same files in the
    # same order. renamed.names keeps both sides of a rename for the code check.
    scanned=1
    [[ "$(yaml_key private)" == "true" ]] && scanned=
    list_changes() {
        { [[ -z "$scanned" ]] ||
            g diff --cached -U0 --no-color --no-ext-diff --no-textconv -M "$base" > "$tmp/staged.diff"; } &&
            g diff --cached --name-only -z -M "$base" > "$tmp/staged.names" &&
            { [[ -z "$scanned" ]] ||
                g diff -U0 --no-color --no-ext-diff --no-textconv > "$tmp/unstaged.diff"; } &&
            g diff --name-only -z > "$tmp/unstaged.names" &&
            g ls-files -z --others --exclude-standard > "$tmp/untracked.names" &&
            g diff --cached --name-only -z --no-renames "$base" > "$tmp/renamed.names"
    }
    list_changes || fail "git could not list the changes in $label"

    # A file name holding a newline is split here; its last part still carries
    # the real extension, so the split can only add code, never hide it.
    code="$(cat "$tmp/renamed.names" "$tmp/unstaged.names" "$tmp/untracked.names" | tr '\0' '\n' | awk '
        NF == 0 { next }
        { b = $0; sub(/.*\//, "", b); e = ""; if (b ~ /.\./) { e = tolower(b); sub(/.*\./, "", e) } }
        e ~ /^(md|txt|pdf|png|jpg|jpeg|gif|webp|svg)$/ { next }
        !seen[$0]++ { n++; if (n <= 5) list = list (n > 1 ? ", " : "") $0 }
        END { if (n > 5) list = list ", and " (n - 5) " more"; printf "%s", list }')"
    if [[ -n "$code" && -z "$review_skip" ]]; then
        [[ -n "$review" ]] || review="$(review_state)"
        [[ -n "$review" ]] || review=unreadable
        skip_hint="to skip deliberately, prefix the commit with KHE_REVIEW_SKIP=\"<reason>\" and tell the operator why"
        [[ "$review" == unreadable ]] &&
            fail "$label commit includes code ($code) and the session transcript '${transcript:-none given}' could not be read to find a /code-review, so a review cannot be seen either; $skip_hint, naming the unreadable transcript"
        [[ "$review" == yes ]] ||
            fail "$label commit includes code ($code) and no /code-review ran in this session. Have Claude run /code-review, fix confirmed findings, then commit; files from another session in this tree need a worktree; $skip_hint"
    fi

    # Only added lines are scanned, so removing personal data never blocks.
    if [[ -n "$scanned" ]]; then
        rules="$root/.claude/hooks/pii-rules.toml"
        command -v gitleaks >/dev/null ||
            fail "gitleaks is not installed, so the personal-data scan cannot run. Install it with 'brew install gitleaks'"
        [[ -f "$rules" ]] || fail "$rules is missing"

        # File names come from the NUL-separated list in $2, not the diff headers,
        # which quote or mangle unusual paths; both list files in the same order.
        split_diff() {
            awk -v dir="$tmp" -v prefix="$3" '
                /^diff --(git|cc|combined) / {
                    if (n) { close(out); close(map) }
                    n++; ln = 0; out = dir "/" prefix n; map = out ".lines"; printf "" > out; printf "" > map; next
                }
                /^@@ / { split($0, h, " "); sub(/^\+/, "", h[3]); split(h[3], c, ","); ln = c[1]; next }
                n && /^\+\+\+ / && !ln { next }
                n && /^\+/ { print substr($0, 2) > out; print ln > map; ln++ }
            ' "$1"
            local i=0 f
            while IFS= read -r -d '' f; do
                i=$((i + 1))
                printf '%s' "$f" > "$tmp/$3$i.name"
            done < "$2"
        }

        split_diff "$tmp/staged.diff" "$tmp/staged.names" s
        split_diff "$tmp/unstaged.diff" "$tmp/unstaged.names" w

        i=0
        while IFS= read -r -d '' f; do
            [[ -f "$top/$f" && ! -L "$top/$f" ]] || continue
            i=$((i + 1))
            (cd "$top" && git -c core.quotePath=false diff --no-index -U0 --no-color --no-ext-diff --no-textconv -- /dev/null "$f") > "$tmp/u$i.diff"
            [[ $? -le 1 ]] || fail "git could not read the untracked file $f for the personal-data scan"
            printf '%s\0' "$f" > "$tmp/u$i.names"
            split_diff "$tmp/u$i.diff" "$tmp/u$i.names" "u$i-"
        done < "$tmp/untracked.names"

        printf '%s\n' "$cmd" > "$tmp/m1"
        awk '{ print NR }' "$tmp/m1" > "$tmp/m1.lines"
        printf 'the commit command or message' > "$tmp/m1.name"
        if [[ "$cmd" =~ (^|[[:space:]])(-F[[:space:]]*|--file=|--file[[:space:]]+)([^[:space:];&|]+) ]]; then
            msg="$(unquote "${BASH_REMATCH[3]}")"
            [[ "$msg" = /* ]] || msg="$dir/$msg"
            if [[ -f "$msg" ]]; then
                cp -- "$msg" "$tmp/m2"
                awk '{ print NR }' "$tmp/m2" > "$tmp/m2.lines"
                printf 'the commit message file %s' "${BASH_REMATCH[3]}" > "$tmp/m2.name"
            fi
        fi

        # gitleaks runs from $tmp so a .gitleaksignore in the repo cannot silence
        # a finding, and --ignore-gitleaks-allow closes the inline allow comment.
        found=()
        for chunk in "$tmp"/*.lines; do
            chunk="${chunk%.lines}"
            [[ -s "$chunk" ]] || continue
            [[ -f "$chunk.name" ]] || printf 'a changed file' > "$chunk.name"
            (cd "$tmp" && gitleaks stdin --config "$rules" --gitleaks-ignore-path "$tmp" \
                --redact --no-banner --no-color --log-level error --ignore-gitleaks-allow \
                --exit-code 3 --report-format json --report-path "$chunk.json" < "$chunk") 2> "$chunk.err"
            rc=$?
            if [[ $rc -eq 3 ]]; then
                n=${#found[@]}
                while IFS=$'\t' read -r rule idx; do
                    found+=("  $(cat "$chunk.name") line $(sed -n "${idx}p" "$chunk.lines"): $rule")
                done < <(jq -r '.[] | [.RuleID, .StartLine] | @tsv' "$chunk.json" 2>/dev/null)
                [[ ${#found[@]} -gt $n ]] || found+=("  $(cat "$chunk.name"): a finding the report did not name")
            elif [[ $rc -ne 0 ]]; then
                {
                    echo "commit-gate: .claude/hooks/pii-rules.toml failed to load (gitleaks exit $rc); commit blocked."
                    head -n 3 "$chunk.err"
                } >&2
                exit 2
            fi
        done
        [[ ${#found[@]} -eq 0 ]] || block "${found[@]}"
    fi

    check="$(yaml_key check)"
    [[ -n "$check" ]] || return 0

    if ! out="$(cd "$top" && bash -c "$check" 2>&1)"; then
        {
            echo "commit-gate: '$check' failed in $label; commit blocked."
            echo "Fix the failure, then commit again. Last lines of output:"
            tail -n 40 <<<"$out"
        } >&2
        exit 2
    fi
}

for d in "${dirs[@]}"; do gate "$d"; done
exit 0
