# Reads a shell command on stdin and prints the reason when a git
# call in it skips the hooks: --no-verify or -n on commit, --no-verify on push,
# or core.hooksPath set (-c, --config-env, an included config file,
# GIT_CONFIG_* in the environment, git config). Prints nothing otherwise.
# commit-gate.sh runs it; it tokenises like the shell (quotes, $'...',
# backslashes, $(...), backticks, heredocs) so a quoted --no-verify or a git
# unique prefix cannot slip past, and a message, heredoc body or other command
# that only mentions one does not block. Any wrapper (timeout, xargs, sudo -u)
# is seen through: the first git word of a command is checked.
function flush_tok() {
    if (has_tok) {
        ntok++
        toks[ntok] = tok
        tok = ""
        has_tok = 0
    }
}
function no_verify(t) {
    sub(/=.*/, "", t)
    return t ~ /^--no-veri/
}
# GIT_CONFIG_* (PARAMETERS, COUNT/KEY_n/VALUE_n, GLOBAL, SYSTEM) set any
# config, core.hooksPath included, for the git calls that see them.
function git_config_env(t) {
    return t ~ /^GIT_CONFIG_[A-Z0-9_]*=/
}
# A config key that sets core.hooksPath, directly or through a file it includes.
function hooks_key(v) {
    v = tolower(v)
    return v ~ /^core\.hookspath=/ || v ~ /^include\.path=/ || v ~ /^includeif\./
}
function check_seg(    i, t, subcmd, k, ch, v) {
    if (ntok == 0) return
    # The first git word, after whatever wrapper runs it, is the call; an
    # assignment or export before it may set GIT_CONFIG_*.
    for (i = 1; i <= ntok; i++) {
        t = toks[i]
        if (t == "git" || t ~ /\/git$/) break
        if (git_config_env(t)) cfg_env = 1
    }
    if (i > ntok) return
    i++
    # Global git options before the subcommand.
    while (i <= ntok) {
        t = toks[i]
        if (substr(t, 1, 2) == "-c" || substr(t, 1, 12) == "--config-env") {
            if (t == "-c" || t == "--config-env") v = toks[++i]
            else if (substr(t, 1, 2) == "-c") v = substr(t, 3)
            else v = substr(t, 14)
            if (hooks_key(v)) {
                msg = "setting core.hooksPath or an included config file can skip git hooks"
                return
            }
            i++
            continue
        }
        if (t == "-C" || t == "--git-dir" || t == "--work-tree" || t == "--namespace" ||
            t == "--super-prefix" || t == "--list-cmds") {
            i += 2
            continue
        }
        if (substr(t, 1, 1) == "-") { i++; continue }
        break
    }
    if (i > ntok) return
    subcmd = toks[i]
    i++
    if (cfg_env && (subcmd == "commit" || subcmd == "push")) {
        msg = "GIT_CONFIG_* in the environment can set core.hooksPath and skip git hooks"
        return
    }
    if (subcmd == "config") {
        v = ""
        for (k = i; k <= ntok; k++) {
            if (tolower(toks[k]) == "core.hookspath") v = 1
            if (toks[k] ~ /^(--get|--get-all|--get-regexp|--list|-l|--unset|--unset-all|get|list|unset)$/) return
        }
        if (v) msg = "setting core.hooksPath skips git hooks"
        return
    }
    if (subcmd == "commit") {
        while (i <= ntok) {
            t = toks[i]
            if (t == "--") break
            if (t == "-m" || t == "-F" || t == "-C" || t == "-c" || t == "-t" ||
                t == "--message" || t == "--file" || t == "--reuse-message" ||
                t == "--reedit-message" || t == "--fixup" || t == "--squash" ||
                t == "--template" || t == "--author" || t == "--date" ||
                t == "--cleanup" || t == "--pathspec-from-file" || t == "--trailer") {
                i += 2
                continue
            }
            # Brace expansion builds the flag the shell passes, as in {--no-verify,}.
            if (t ~ /[{,]--no-veri/ || t ~ /[{,]-[A-Za-z]*n[A-Za-z]*[,}]/) {
                msg = "--no-verify or -n on a commit skips git hooks"
                return
            }
            if (substr(t, 1, 2) == "--") {
                if (no_verify(t)) {
                    msg = "--no-verify or -n on a commit skips git hooks"
                    return
                }
                i++
                continue
            }
            if (substr(t, 1, 1) == "-" && length(t) >= 2) {
                for (k = 2; k <= length(t); k++) {
                    ch = substr(t, k, 1)
                    if (ch == "n") {
                        msg = "--no-verify or -n on a commit skips git hooks"
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
                t == "--receive-pack" || t == "--exec") {
                i += 2
                continue
            }
            if (substr(t, 1, 2) == "--" || t ~ /[{,]--no-veri/) {
                if (no_verify(t) || t ~ /[{,]--no-veri/) {
                    msg = "--no-verify on a push skips git hooks"
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
# (...), $(...) and backticks (kind 0, 1, 2) open a command of their own, with
# fresh quoting even inside double quotes. A substitution is part of the word
# around it, so the outer command's words are kept aside and restored, with the
# substitution's output standing in as "$": a --no-verify after it still counts.
function open_sub(kind,    j) {
    if (kind == 0) flush_seg()
    depth++
    skind[depth] = kind
    sq[depth] = q
    sn[depth] = ntok
    for (j = 1; j <= ntok; j++) stoks[depth, j] = toks[j]
    stok[depth] = tok
    ntok = 0
    tok = ""
    has_tok = 0
    q = ""
}
function close_sub(    j) {
    flush_seg()
    if (depth == 0) return
    q = sq[depth]
    if (skind[depth] != 0) {
        ntok = sn[depth]
        for (j = 1; j <= ntok; j++) toks[j] = stoks[depth, j]
        tok = stok[depth] "$"
        has_tok = 1
    }
    depth--
}
BEGIN { q = ""; tok = ""; has_tok = 0; ntok = 0; depth = 0; in_hd = 0; hd = ""; pending_hd = ""; msg = ""; cfg_env = 0 }
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
            # $'...' and $"..." are quotes too.
            if (c == "$" && (substr(line, i + 1, 1) == "\047" || substr(line, i + 1, 1) == "\"")) {
                i++
                q = substr(line, i, 1)
                has_tok = 1
                continue
            }
            if (c == "#" && !has_tok) break
            if (substr(line, i, 3) == "<<<") { flush_tok(); i += 2; continue }
            # The delimiter is the whole word after <<, quotes and backslashes
            # removed, as the shell reads it.
            if (substr(line, i, 2) == "<<") {
                flush_tok()
                rest = substr(line, i + 2)
                if (match(rest, /^-?[ \t]*[^ \t;&|()<>]+/)) {
                    d = substr(rest, RSTART, RLENGTH)
                    sub(/^-?[ \t]*/, "", d)
                    gsub(/[\047"\\]/, "", d)
                    pending_hd = d
                    i += 1 + RSTART + RLENGTH - 1
                } else {
                    i++
                }
                continue
            }
            # Arithmetic $((...)) holds no command, and its << is a shift.
            if (substr(line, i, 3) == "$((" && (k = index(substr(line, i + 3), "))")) > 0) {
                tok = tok "$"
                has_tok = 1
                i += k + 3
                continue
            }
            if (substr(line, i, 2) == "$(") { open_sub(1); i++; continue }
            if (c == "(") { open_sub(0); continue }
            if (c == ")") { close_sub(); continue }
            if (c == "`") {
                if (depth > 0 && skind[depth] == 2) close_sub()
                else open_sub(2)
                continue
            }
            if (index(";&|", c) > 0) { flush_seg(); continue }
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
                open_sub(1)
                i++
            } else if (c == "`") {
                open_sub(2)
            } else {
                tok = tok c
            }
        }
    }
    if (!cont && q == "") flush_seg()
    if (pending_hd != "") { in_hd = 1; hd = pending_hd; pending_hd = "" }
}
END {
    while (depth > 0) close_sub()
    flush_seg()
    if (msg != "") print msg
}
