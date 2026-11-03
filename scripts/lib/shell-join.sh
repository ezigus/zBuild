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
    # D (double quotes) and C (a $( ) — code again, inside double quotes too).
    code = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); c2 = substr(s, i, 2); top = ctx[depth]
        if (top == "S") { if (c == "\047") depth--; code = code " "; continue }
        if (top == "D") {
            if (c == "\\") { i++; code = code "  "; continue }
            if (c == "\"") { depth--; code = code " "; continue }
            if (c2 == "$(") { ctx[++depth] = "C"; par[depth] = 0; code = code c2; i++; continue }
            code = code " "; continue
        }
        if (c == "\\") { code = code c2; i++; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|()]/)) break
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
        print raw; next
    }
    wasq = (ctx[depth] == "S" || ctx[depth] == "D")
    code = scan(raw)
    if (!wasq && match(code, /<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*/) && substr(code, RSTART, 3) != "<<<") {
        h = substr(raw, RSTART, RLENGTH + 2); hd_tabs = (h ~ /^<<-/)
        gsub(/^<<-?[ \t]*|[\047"]/, "", h); sub(/[^A-Za-z0-9_].*$/, "", h); hd = h
    }
    t = code; sub(/[ \t]+$/, "", t)
    top = ctx[depth]
    cont = ((top == "N" || top == "C") && hd == "" && (t ~ /\\$/ || t ~ /(\||&&)$/) && t !~ /;;$/)
    line = raw
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
