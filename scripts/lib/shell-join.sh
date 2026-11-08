#!/usr/bin/env bash
# scripts/lib/shell-join.sh — a shell file read as whole commands (#2460).
#
# The repository's lints check shell code a line at a time, so a command that
# carries on to the next line — a trailing `\`, or a line ending in `|`, `&&` or
# `||` — slipped past them, or tripped them falsely. zb_shell_join prints the
# file with each such command joined onto its first line and the lines it took
# left blank: the line count, and so every line number a lint reports, is kept.
# A backslash or an operator inside quotes, in a comment or in a heredoc body
# joins nothing.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_SHELL_JOIN_LOADED:-}" ]] && return 0
_ZBUILD_SHELL_JOIN_LOADED=1

_ZB_SHELL_JOIN_AWK='
function scan(s,   i, n, c, c2, code, top) {
    # Returns the line with quoted text and any comment blanked. The quoting
    # carries across lines: ctx[] is a stack of N (code), S (single quotes),
    # A ($'...', where a backslash escapes), D (double quotes) and C (a $( ) —
    # code again, inside double quotes too).
    code = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); c2 = substr(s, i, 2); top = ctx[depth]
        if (top == "S") { if (c == "\047") depth--; code = code " "; continue }
        if (top == "A") {
            if (c == "\\") { i++; code = code "  "; continue }
            if (c == "\047") depth--
            code = code " "; continue
        }
        if (top == "D") {
            if (c == "\\") { i++; code = code "  "; continue }
            if (c == "\"") { depth--; code = code " "; continue }
            if (c2 == "$(") { ctx[++depth] = "C"; par[depth] = 0; code = code c2; i++; continue }
            code = code " "; continue
        }
        if (c == "\\") { code = code c2; i++; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|()]/)) break
        if (c2 == "$\047") { ctx[++depth] = "A"; code = code "  "; i++; continue }
        if (c == "\047") { ctx[++depth] = "S"; code = code " "; continue }
        if (c == "\"") { ctx[++depth] = "D"; code = code " "; continue }
        if (c2 == "$(") { ctx[++depth] = "C"; par[depth] = 0; code = code c2; i++; continue }
        if (c == "(") par[depth]++
        if (c == ")") { if (par[depth] > 0) par[depth]--; else if (top == "C") depth-- }
        code = code c
    }
    return code
}
FNR == 1 { if (held) emit(); depth = 0; ctx[0] = "N"; par[0] = 0; hd = ""; buf = ""; held = 0 }
{
    raw = $0
    if (hd != "") {
        t = raw; if (hd_tabs) sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        if (!ascode) print raw
        next
    }
    wasq = (ctx[depth] == "S" || ctx[depth] == "A" || ctx[depth] == "D")
    code = scan(raw)
    # The opener is found in the code (a << inside quotes is not one), its word
    # read from the raw line: a quoted word, <<\047EOF\047, is blanked in the code
    # (review on #2461).
    if (!wasq && match(code, /<<-?/) && substr(code, RSTART, 3) != "<<<") {
        h = substr(raw, RSTART); hd_tabs = (h ~ /^<<-/)
        sub(/^<<-?[ \t]*/, "", h); gsub(/[\047"]/, "", h); sub(/[^A-Za-z0-9_].*$/, "", h)
        if (h ~ /^[A-Za-z_]/) hd = h
    }
    t = code; sub(/[ \t]+$/, "", t)
    top = ctx[depth]
    cont = ((top == "N" || top == "C") && hd == "" && (t ~ /\\$/ || t ~ /(\||&&)$/) && t !~ /;;$/)
    line = ascode ? code : raw
    if (t ~ /\\$/ && cont) { sub(/[ \t]*\\[ \t]*$/, "", line) }
    if (held) { s = line; sub(/^[ \t]+/, "", s); buf = buf " " s; blanks++ }
    else { buf = line; blanks = 0 }
    if (cont) { held = 1; next }
    emit()
}
function emit(   k) {
    if (named) { if (buf ~ /[^ \t]/) print FILENAME ":" (FNR - blanks) ":" buf }
    else { print buf; for (k = 0; k < blanks; k++) print "" }
    held = 0; buf = ""
}
END { if (held) emit() }
'

# zb_shell_join <file>... — each file, its commands joined onto their first line.
zb_shell_join() {
    awk "$_ZB_SHELL_JOIN_AWK" "$@"
}

# zb_shell_join_named <file>... — the same, as `<file>:<line>:<command>` for
# each line that holds a command, the way `grep -n` names a hit.
zb_shell_join_named() {
    awk -v named=1 "$_ZB_SHELL_JOIN_AWK" "$@"
}

# zb_shell_code_named <file>... — the same, each command as code only: quoted
# text and comments blanked, heredoc bodies left out. For a lint that asks what
# a file runs, not what it says.
zb_shell_code_named() {
    awk -v named=1 -v ascode=1 "$_ZB_SHELL_JOIN_AWK" "$@"
}
