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
#
# The scan line also says where a cd, pushd or popd stops counting, for the
# gate's walk(). Only one the shell runs as a command (after if, {, an
# assignment, builtin or command) is written there, as a command of its own,
# and the segments ( and ) enclose a subshell: a ( ... ) group, a pipeline
# element that runs in one in every shell, a list run with &. The segments (?
# and ) enclose a part that may not run (what follows && or ||, an if, loop or
# case body) or that runs in a subshell in bash but not in zsh (the last
# element of a pipeline): a cd inside one leaves the directory unknown after
# it. The segment ? makes it unknown from there on: after a function
# definition, whose body may run later, at the start of a loop with a cd in
# it, and for a cd with an empty word.
function flush_tok() {
    if (has_tok) {
        ntok++
        toks[ntok] = tok
        sts[ntok] = st
        tqs[ntok] = tq
        tok = ""
        st = ""
        has_tok = 0
        cut = 0
        tq = 0
    }
}
# tok is a word as the command sees it, st its scan form; qs holds the quoted
# part being read, which goes to st whole when the quote closes.
# cut is set by a NUL in $'...', where the shell ends the word it passes on.
# tq is set when any part of the word is quoted or escaped: such a word is never
# a reserved word or an assignment to the shell.
function addu(x) { has_tok = 1; if (!cut) { tok = tok x; st = st x } }
function adde(x) { has_tok = 1; tq = 1; if (!cut) { tok = tok x; st = st (x ~ META ? "Q" : x) } }
function addq(x) { tq = 1; if (!cut) { tok = tok x; qs = qs x } }
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
function emit(a, b,    j, out) {
    out = ""
    for (j = a; j <= b; j++) if (sts[j] != DROP) out = out (out == "" ? "" : " ") sts[j]
    if (out != "") scan = scan out ";"
}
function flush_seg(    j, k, m, hdr, empty, body, other) {
    flush_tok()
    if (msg == "") check_seg()
    if (ntok == 0) return
    pend = 0
    # Reserved words that open the command act on the frames; the words after
    # for, select, case or function are a header, not a command.
    for (k = 1; k <= ntok && !hdr && toks[k] ~ RESERVED && !tqs[k]; k++) {
        hdr = keyword(toks[k])
        # function takes the name, and its body may follow on the line.
        if (hdr == 2) { hdr = 0; k++ }
    }
    if (hdr) { ntok = 0; return }
    # zsh takes a simple command as a function body, which also runs later.
    if (funcpend && k <= ntok) {
        funcpend = 0
        body = 1
        scan = scan "(;?;"
    }
    # Only an assignment or builtin before it leaves cd the shell's own cd in
    # both shells (zsh runs `command cd` as /usr/bin/cd).
    for (j = k; j <= ntok && !tqs[j] && (toks[j] ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || toks[j] == "builtin"); j++) ;
    for (m = j + 1; m <= ntok; m++) if (toks[m] ~ CDWORD) other = 1
    if (j <= ntok && toks[j] ~ CDWORD) {
        emit(k, j - 1)
        sts[j] = (toks[j] == "chdir") ? "cd" : toks[j]
        for (k = j + 1; k <= ntok; k++) if (sts[k] == "") empty = 1
        # The shell may drop an empty word, as in cd "".
        if (empty) scan = scan "?;"
        else emit(j, ntok)
        mark_loops()
    } else {
        emit(k, ntok)
        # A cd behind a word the awk does not follow (command, eval, repeat,
        # an option) may run or not.
        if (other) {
            scan = scan "?;"
            mark_loops()
        }
    }
    if (body) scan = scan ");?;"
    ntok = 0
}
# Frames: the top level, each ( ... ) and substitution, and each compound
# command. felem and flist are where the current pipeline element and and-or
# list start on the scan line, fpiped whether that pipeline has had a |, fmay
# how many (? the list has open, fors whether it has had a ||, fstart where the
# frame starts, fdir whether a loop has a cd in it, fpat whether a case is at a
# pattern rather than in an arm.
function push_frame(t) {
    nf++
    ftype[nf] = t
    fstart[nf] = felem[nf] = flist[nf] = length(scan)
    fpiped[nf] = fmay[nf] = fors[nf] = fdir[nf] = 0
    fpat[nf] = (t == "case")
    farith[nf] = 0
    # A function body runs later, from wherever the call is: it starts and
    # leaves the directory unknown.
    ffunc[nf] = funcpend && (t == "brace" || t == "paren")
    if (ffunc[nf]) {
        funcpend = 0
        if (t == "brace") scan = scan "(;"
        scan = scan "?;"
        fstart[nf] = felem[nf] = flist[nf] = length(scan)
    }
}
function is_scope(f) { return ftype[f] == "paren" || ftype[f] == "sub" }
function wrap(p, open) { scan = substr(scan, 1, p) open ";" substr(scan, p + 1) ");" }
function end_pipe() {
    if (fpiped[nf]) wrap(felem[nf], "(?")
    fpiped[nf] = 0
}
function close_may() {
    for (; fmay[nf] > 0; fmay[nf]--) scan = scan ");"
}
function end_list() {
    end_pipe()
    close_may()
    fors[nf] = 0
    felem[nf] = flist[nf] = length(scan)
}
# After `a || b`, a later && runs whether or not b ran, so a || closes the
# list's (? and opens a fresh one.
function on_sep(op) {
    pend = (op == "|" || op == "&&" || op == "||")
    if (op == "|") {
        wrap(felem[nf], "(")
        fpiped[nf] = 1
        felem[nf] = length(scan)
        return
    }
    if (op == "&&" || op == "||") {
        end_pipe()
        if (op == "||" || fors[nf]) close_may()
        if (op == "||") fors[nf] = 1
        scan = scan "(?;"
        fmay[nf]++
        felem[nf] = length(scan)
        return
    }
    if (op == "&") {
        end_pipe()
        close_may()
        wrap(flist[nf], "(")
    }
    end_list()
    if (op == ";;" && ftype[nf] == "case" && !fpat[nf]) {
        scan = scan ");"
        fpat[nf] = 1
    }
}
# Returns 1 when a | ( or ) at this point is part of a case pattern: the case
# frame waits for one, or the pending words are `case <word> in`, which the
# frame is opened for here.
# pat_words is how many words of the pattern came before it.
function in_pattern(    k) {
    flush_tok()
    if (ftype[nf] == "case" && fpat[nf]) {
        pat_words = ntok
        return !(ntok == 1 && toks[1] == "esac" && !tqs[1])
    }
    for (k = 1; k <= ntok && toks[k] ~ RESERVED && !tqs[k] && toks[k] != "case"; k++) ;
    if (!(toks[k] == "case" && !tqs[k] && k + 2 <= ntok && toks[k + 2] == "in")) return 0
    pat_words = ntok - k - 2
    ntok = k + 2
    flush_seg()
    return 1
}
# A ( inside a pattern, as in @(a|b), nests; a leading one does not. The ) that
# ends the pattern opens its arm, which may not run.
function pattern_char(c) {
    if (c == "(" && pat_words) pdepth++
    else if (c == ")" && pdepth) pdepth--
    else if (c == ")") open_arm()
}
function open_arm() {
    ntok = 0
    pdepth = 0
    fpat[nf] = 0
    scan = scan "(?;"
    felem[nf] = flist[nf] = length(scan)
}
# Returns 1 when the words after w are a header (for, select, case) rather
# than a command, 2 when the next word is (function's name).
function keyword(w) {
    if (w == "{") {
        push_frame("brace")
    } else if (w == "case") {
        push_frame("case")
        return 1
    } else if (w ~ /^(if|while|until|for|select)$/) {
        scan = scan "(?;"
        push_frame(w == "if" ? "if" : "loop")
        return w == "for" || w == "select"
    } else if (w ~ /^(then|else|elif|do)$/) {
        end_list()
        if (ftype[nf] == "if") scan = scan ");(?;"
        felem[nf] = flist[nf] = length(scan)
    } else if (w ~ /^(}|fi|done|esac)$/) {
        if (nf > 0 && !is_scope(nf)) close_compound()
    } else if (w == "function") {
        funcpend = 1
        return 2
    }
    return 0
}
function close_compound() {
    end_list()
    if (ftype[nf] == "if" || ftype[nf] == "loop" || ffunc[nf] || (ftype[nf] == "case" && !fpat[nf])) scan = scan ");"
    if (ffunc[nf]) scan = scan "?;"
    # A later pass of the loop runs where an earlier pass left it.
    if (fdir[nf]) scan = substr(scan, 1, fstart[nf]) "?;" substr(scan, fstart[nf] + 1)
    nf--
}
# Marks each loop around this point in the subshell as holding a cd.
function mark_loops(    f) {
    for (f = nf; f > 0 && !is_scope(f); f--) if (ftype[f] == "loop") fdir[f] = 1
}
# (...), $(...) and backticks (kind 0, 1, 2) open a command of their own, with
# fresh quoting even inside double quotes. A substitution is part of the word
# around it, so the outer command's words are kept aside and restored, with the
# substitution's output standing in as "$": a --no-verify after it still counts.
# Each runs in a subshell, enclosed in ( and ) on the scan line, and a commit
# or push inside a substitution is reported as `nested`, which the gate refuses.
function open_sub(kind,    j) {
    if (kind == 0) {
        flush_tok()
        # name() defines a function, whose body is the next command.
        if (ntok > 0 && match(substr(line, i + 1), /^[ \t]*\)/)) {
            i += RLENGTH
            flush_seg()
            funcpend = 1
            return
        }
        flush_seg()
    }
    scan = scan "(;"
    push_frame(kind == 0 ? "paren" : "sub")
    # (( opens an arithmetic command.
    farith[nf] = kind == 0 && (substr(line, i + 1, 1) == "(" || substr(line, i - 1, 1) == "(" || farith[nf - 1])
    depth++
    if (kind != 0) insub++
    skind[depth] = kind
    sq[depth] = q
    sn[depth] = ntok
    for (j = 1; j <= ntok; j++) { stoks[depth, j] = toks[j]; ssts[depth, j] = sts[j] }
    stok[depth] = tok
    stq[depth] = tq
    sst[depth] = st
    sqs[depth] = qs
    ntok = 0
    tok = ""
    st = ""
    qs = ""
    has_tok = 0
    tq = 0
    q = ""
}
function close_sub(    j) {
    flush_seg()
    if (depth == 0) return
    while (nf > 0 && !is_scope(nf)) close_compound()
    end_list()
    scan = scan ");" (ffunc[nf] ? "?;" : "")
    if (nf > 0) nf--
    q = sq[depth]
    if (skind[depth] != 0) {
        insub--
        ntok = sn[depth]
        for (j = 1; j <= ntok; j++) { toks[j] = stoks[depth, j]; sts[j] = ssts[depth, j] }
        tok = stok[depth]
        tq = stq[depth]
        st = sst[depth]
        qs = sqs[depth]
        if (q == "") addu("$"); else addq("$")
        has_tok = 1
    }
    depth--
}
BEGIN {
    q = ""; tok = ""; st = ""; qs = ""; has_tok = 0; ntok = 0; depth = 0
    in_hd = 0; msg = ""; cfg_env = 0; runs = ""; scan = ""; insub = 0; cut = 0
    META = "[[:space:];&|()<>`]"
    DROP = "\001"
    ESC_CHARS = "abfnrtvEe"
    split("7 8 12 10 13 9 11 27 27", ESC_CODES, " ")
    RESERVED = "^([{}!]|if|then|else|elif|fi|while|until|for|select|do|done|case|esac|time|function)$"
    nf = 0; pend = 0; funcpend = 0; pdepth = 0; pat_words = 0; tq = 0; nhd = 0
    CDWORD = "^(cd|chdir|pushd|popd)$"
}
{
    if (msg != "") next
    line = $0
    # A heredoc ends at a line that is exactly its delimiter, after leading
    # tabs for <<-; several on one line are read in turn.
    if (in_hd) {
        t = line
        if (hdash[in_hd]) sub(/^\t+/, "", t)
        if (t == hdq[in_hd] && ++in_hd > nhd) in_hd = nhd = 0
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
            if (c == "\047" || c == "\"") { q = c; has_tok = 1; tq = 1; continue }
            # $'...' (q is "$") and $"..." are quotes too.
            if (c == "$" && (substr(line, i + 1, 1) == "\047" || substr(line, i + 1, 1) == "\"")) {
                i++
                q = substr(line, i, 1)
                if (q == "\047") q = "$"
                has_tok = 1
                tq = 1
                continue
            }
            if (c == "#" && !has_tok) break
            # A here-string stays a word of its own, so its operand is not
            # read as an argument.
            if (substr(line, i, 3) == "<<<") { flush_tok(); addu("<<<"); flush_tok(); i += 2; continue }
            # The delimiter is the whole word after <<, quotes and backslashes
            # removed, as the shell reads it.
            # In (( ... )) and $[ ... ] << is a shift.
            if (substr(line, i, 2) == "<<" && (farith[nf] || st ~ /\$\[[^]]*$/)) { addu("<<"); i++; continue }
            if (substr(line, i, 2) == "<<") {
                flush_tok()
                rest = substr(line, i + 2)
                if (match(rest, /^-?[ \t]*\047[^\047]*\047/) || match(rest, /^-?[ \t]*"[^"]*"/) ||
                    match(rest, /^-?[ \t]*[^ \t;&|()<>]+/)) {
                    d = substr(rest, RSTART, RLENGTH)
                    hdash[++nhd] = (substr(d, 1, 1) == "-")
                    sub(/^-?[ \t]*/, "", d)
                    gsub(/[\047"\\]/, "", d)
                    hdq[nhd] = d
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
            if ((c == "(" || c == "|" || c == ")") && in_pattern()) {
                pattern_char(c)
                continue
            }
            if (c == "(") { open_sub(0); continue }
            if (c == ")") { close_sub(); continue }
            if (c == "`") {
                if (depth > 0 && skind[depth] == 2) close_sub()
                else open_sub(2)
                continue
            }
            # >&, <& and &> redirect; they do not end the command.
            if (c == "&" && (st ~ /[<>]$/ || substr(line, i + 1, 1) == ">")) { addu(c); continue }
            if (c == "|" && st ~ />$/) { addu(c); continue }
            if (index(";&|", c) > 0) {
                flush_seg()
                nc = substr(line, i + 1, 1)
                op = c
                if (c == "|" && nc == "|") { op = "||"; i++ }
                else if (c == "|" && nc == "&") i++
                else if (c == "&" && nc == "&") { op = "&&"; i++ }
                else if (c == ";" && (nc == ";" || nc == "&")) {
                    # ;; ;& and ;;& end a case arm.
                    op = ";;"
                    i++
                    if (nc == ";" && substr(line, i + 1, 1) == "&") i++
                }
                on_sep(op)
                continue
            }
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
    # A newline ends the list unless the line ends in |, && or ||.
    if (!cont && q == "") {
        flush_seg()
        if (!pend) on_sep(";")
    }
    if (nhd && !cont && q == "") in_hd = 1
}
END {
    while (depth > 0) close_sub()
    if (q != "") endq()
    flush_seg()
    while (nf > 0) close_compound()
    end_list()
    if (msg != "") print "bypass " msg
    printf "%s", runs
    print "scan " scan
}
