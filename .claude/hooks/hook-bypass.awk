# Reads a shell command on stdin and prints `bypass <reason>` when a git
# call in it skips the hooks: --no-verify or -n on commit, --no-verify on push,
# or core.hooksPath set (-c, --config-env, an included config file,
# GIT_CONFIG_* in the environment, git config). It also prints `commit` or
# `push` for each git call that runs one, and last `scan <line>`, the line
# commit-gate.sh matches its rules against. commit-gate.sh runs it; it
# tokenises like the shell (quotes, $'...' with its escapes decoded,
# backslashes, $(...), backticks, heredocs, comments) so a quoted --no-verify,
# a quoted subcommand or a git unique prefix cannot slip past, and a message,
# heredoc body or other command that only mentions one does not block. Any
# wrapper (timeout, xargs, sudo -u) is seen through: the first git word of a
# command is checked.
#
# The scan line holds each command's words joined by spaces and ended by ;,
# with quotes and escapes dropped as the shell drops them, except that a
# quoted or escaped part holding a space, a newline or a shell operator becomes
# Q, so a message that mentions a git command reads as one word. A git option
# whose value is a separate word is written --opt=value and -cX as -c X, the
# forms the gate's regexes read.
function flush_tok() {
    if (has_tok) {
        ntok++
        toks[ntok] = tok
        sts[ntok] = st
        tok = ""
        st = ""
        has_tok = 0
        cut = 0
    }
}
# tok is a word as the command sees it, st its scan form; qs holds the quoted
# part being read, which goes to st whole when the quote closes.
# cut is set by a NUL in $'...', where the shell ends the word it passes on.
function addu(x) { has_tok = 1; if (!cut) { tok = tok x; st = st x } }
function adde(x) { has_tok = 1; if (!cut) { tok = tok x; st = st (x ~ META ? "Q" : x) } }
function addq(x) { if (!cut) { tok = tok x; qs = qs x } }
function endq() { st = st (qs ~ META ? "Q" : qs); qs = ""; q = "" }
function chr(v) {
    if (v == 0) { cut = 1; return "" }
    return (v < 128) ? sprintf("%c", v) : "?"
}
# Adds the $'...' escape at s[i] (the character after the backslash) to the
# word and returns the index of its last character. zsh and bash differ on \u and
# \c and on unknown escapes; where they do, the result is the more readable one,
# since a git word read too generously only adds a check.
function ansi_esc(s, i,    c, m, v, k) {
    c = substr(s, i, 1)
    if (c == "x" || c == "u" || c == "U") {
        k = (c == "x") ? 2 : (c == "u") ? 4 : 8
        v = 0
        for (m = 0; m < k && substr(s, i + 1, 1) != "" && index("0123456789abcdefABCDEF", substr(s, i + 1, 1)) > 0; m++) {
            i++
            v = v * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
        }
        addq(m ? chr(v) : c)
        return i
    }
    # index(s, "") is 1 in BSD awk, hence the guards against an empty c.
    if (c != "" && index("01234567", c) > 0) {
        v = c + 0
        for (m = 1; m < 3 && substr(s, i + 1, 1) != "" && index("01234567", substr(s, i + 1, 1)) > 0; m++) {
            i++
            v = v * 8 + substr(s, i, 1)
        }
        addq(chr(v))
        return i
    }
    k = index(ESC_CHARS, c)
    addq((c != "" && k > 0) ? chr(ESC_CODES[k]) : c)
    return i
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
# Writes the option at sts[i] and its value as one word, --opt=value.
function join_next(i) {
    if (i < ntok) { sts[i] = sts[i] "=" sts[i + 1]; sts[i + 1] = DROP }
}
function check_seg(    i, t, subcmd, k, ch, v) {
    if (ntok == 0) return
    # The first git word, after whatever wrapper runs it, is the call; an
    # assignment or export before it may set GIT_CONFIG_*.
    for (i = 1; i <= ntok; i++) {
        t = toks[i]
        # zsh runs =git as the git on PATH.
        if (t == "git" || t ~ /\/git$/ || t == "=git") { if (t == "=git") sts[i] = "git"; break }
        if (git_config_env(t)) cfg_env = 1
    }
    if (i > ntok) return
    i++
    # Global git options before the subcommand.
    while (i <= ntok) {
        t = toks[i]
        if (substr(t, 1, 2) == "-c" || substr(t, 1, 12) == "--config-env") {
            if (t == "-c" || t == "--config-env") {
                v = toks[i + 1]
                if (t == "--config-env") join_next(i)
                i++
            } else if (substr(t, 1, 2) == "-c") {
                v = substr(t, 3)
                sts[i] = "-c " substr(sts[i], 3)
            } else v = substr(t, 14)
            if (hooks_key(v)) {
                msg = "setting core.hooksPath or an included config file can skip git hooks"
                return
            }
            i++
            continue
        }
        if (t == "-C" || t == "--git-dir" || t == "--work-tree" || t == "--namespace" ||
            t == "--super-prefix" || t == "--list-cmds" || t == "--attr-source") {
            if (t != "-C") join_next(i)
            i += 2
            continue
        }
        if (substr(t, 1, 1) == "-") { i++; continue }
        break
    }
    if (i > ntok) return
    subcmd = toks[i]
    i++
    if (subcmd == "commit" || subcmd == "push") runs = runs (insub ? "nested " : "") subcmd "\n"
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
function flush_seg(    j, out) {
    flush_tok()
    if (msg == "") check_seg()
    if (ntok > 0) {
        if (insub && (toks[1] == "cd" || toks[1] == "pushd")) sts[1] = "Q"
        out = ""
        for (j = 1; j <= ntok; j++) if (sts[j] != DROP) out = out (out == "" ? "" : " ") sts[j]
        scan = scan out ";"
    }
    ntok = 0
}
# (...), $(...) and backticks (kind 0, 1, 2) open a command of their own, with
# fresh quoting even inside double quotes. A substitution is part of the word
# around it, so the outer command's words are kept aside and restored, with the
# substitution's output standing in as "$": a --no-verify after it still counts.
# A substitution runs in a subshell, so its cd and pushd are scanned as Q and
# cannot move where the gate thinks a later git call runs, and a commit or push
# inside one is reported as `nested`, which the gate refuses.
function open_sub(kind,    j) {
    if (kind == 0) flush_seg()
    depth++
    if (kind != 0) insub++
    skind[depth] = kind
    sq[depth] = q
    sn[depth] = ntok
    for (j = 1; j <= ntok; j++) { stoks[depth, j] = toks[j]; ssts[depth, j] = sts[j] }
    stok[depth] = tok
    sst[depth] = st
    sqs[depth] = qs
    ntok = 0
    tok = ""
    st = ""
    qs = ""
    has_tok = 0
    q = ""
}
function close_sub(    j) {
    flush_seg()
    if (depth == 0) return
    q = sq[depth]
    if (skind[depth] != 0) {
        insub--
        ntok = sn[depth]
        for (j = 1; j <= ntok; j++) { toks[j] = stoks[depth, j]; sts[j] = ssts[depth, j] }
        tok = stok[depth]
        st = sst[depth]
        qs = sqs[depth]
        if (q == "") addu("$"); else addq("$")
        has_tok = 1
    }
    depth--
}
BEGIN {
    q = ""; tok = ""; st = ""; qs = ""; has_tok = 0; ntok = 0; depth = 0
    in_hd = 0; hd = ""; pending_hd = ""; msg = ""; cfg_env = 0; runs = ""; scan = ""; insub = 0; cut = 0
    META = "[[:space:];&|()<>`]"
    DROP = "\001"
    ESC_CHARS = "abfnrtvEe"
    split("7 8 12 10 13 9 11 27 27", ESC_CODES, " ")
}
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
                adde(substr(line, i, 1))
                continue
            }
            if (c == "\047" || c == "\"") { q = c; has_tok = 1; continue }
            # $'...' (q is "$") and $"..." are quotes too.
            if (c == "$" && (substr(line, i + 1, 1) == "\047" || substr(line, i + 1, 1) == "\"")) {
                i++
                q = substr(line, i, 1)
                if (q == "\047") q = "$"
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
                if (match(rest, /^-?[ \t]*\047[^\047]*\047/) || match(rest, /^-?[ \t]*"[^"]*"/) ||
                    match(rest, /^-?[ \t]*[^ \t;&|()<>]+/)) {
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
            # One holding $( or a backtick is read as substitutions instead.
            if (substr(line, i, 3) == "$((" && (k = index(substr(line, i + 3), "))")) > 0 &&
                substr(line, i + 3, k - 1) !~ /\$\(|`/) {
                addu("$")
                i += k + 3
                continue
            }
            if (substr(line, i, 2) == "$(") { open_sub(1); i++; continue }
            # <(...) and >(...) are substitutions inside the command's words.
            if (c == "(" && st ~ /[<>]$/) { open_sub(1); continue }
            if (c == "(") { open_sub(0); continue }
            if (c == ")") { close_sub(); continue }
            if (c == "`") {
                if (depth > 0 && skind[depth] == 2) close_sub()
                else open_sub(2)
                continue
            }
            # >&, <& and &> redirect; they do not end the command.
            if (c == "&" && (st ~ /[<>]$/ || substr(line, i + 1, 1) == ">")) { addu(c); continue }
            if (index(";&|", c) > 0) { flush_seg(); continue }
            if (c == " " || c == "\t") { flush_tok(); continue }
            addu(c)
        } else if (q == "\047") {
            if (c == "\047") endq()
            else addq(c)
        } else if (q == "$") {
            if (c == "\047") endq()
            else if (c == "\\" && i < n) i = ansi_esc(line, i + 1)
            else addq(c)
        } else {
            if (c == "\\" && i == n) {
                cont = 1
            } else if (c == "\\") {
                nc = substr(line, i + 1, 1)
                if (index("\"\\$`", nc) > 0) { i++; addq(nc) }
                else addq(c)
            } else if (c == "\"") {
                endq()
            } else if (substr(line, i, 2) == "$(") {
                open_sub(1)
                i++
            } else if (c == "`") {
                open_sub(2)
            } else {
                addq(c)
            }
        }
    }
    if (!cont && q != "") addq("\n")
    if (!cont && q == "") flush_seg()
    if (pending_hd != "") { in_hd = 1; hd = pending_hd; pending_hd = "" }
}
END {
    while (depth > 0) close_sub()
    if (q != "") endq()
    flush_seg()
    if (msg != "") print "bypass " msg
    printf "%s", runs
    print "scan " scan
}
