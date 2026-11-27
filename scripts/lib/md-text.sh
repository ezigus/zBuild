#!/usr/bin/env bash
# scripts/lib/md-text.sh — the one place the shell writes text into GitHub
# markdown (ADR-065 §5: by the shell, no process). CommonMark is the reference:
# any ASCII punctuation character may be escaped with a backslash and then
# shows as itself, and a fenced block ends only on a run of backticks as long
# as the one that opened it. GitHub adds what is not markdown — an @ mentions
# someone, a # before a digit links an issue, :// makes a link — and a
# zero-width space after the @, the # or the : stops each. And a terminal's
# escapes are taken out of text here too (zb_ansi_strip_v), for a short
# string; a whole captured output is sed's (core/output/stage-io.sh).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_MD_TEXT_LOADED:-}" ]] && return 0
_ZBUILD_MD_TEXT_LOADED=1

ZB_MD_ZWSP=$'\xe2\x80\x8b'
# Every ASCII punctuation character but the backslash, which goes first.
_ZB_MD_PUNCT='!"#$%&'"'"'()*+,-./:;<=>?@[]^_`{|}~'

# zb_md_text_v <var> <text> — <text> shown as written: a backslash before each
# ASCII punctuation character; an @, a # before a digit and :// stopped.
# Letters, digits, spaces, newlines and non-ASCII text are as they are.
zb_md_text_v() {
    local LC_ALL=C _zmt="$2" _zmt_c _zmt_d
    local -i _zmt_i
    _zmt="${_zmt//\\/\\\\}"
    for (( _zmt_i = 0; _zmt_i < ${#_ZB_MD_PUNCT}; _zmt_i++ )); do
        _zmt_c="${_ZB_MD_PUNCT:_zmt_i:1}"
        [[ "$_zmt" == *"$_zmt_c"* ]] && _zmt="${_zmt//"$_zmt_c"/"\\$_zmt_c"}"
    done
    _zmt="${_zmt//\\@/"\\@$ZB_MD_ZWSP"}"
    _zmt="${_zmt//\\:\\\/\\\//"\\:$ZB_MD_ZWSP\\/\\/"}"
    if [[ "$_zmt" == *\\#[0-9]* ]]; then
        for _zmt_d in 0 1 2 3 4 5 6 7 8 9; do _zmt="${_zmt//"\\#$_zmt_d"/"\\#$ZB_MD_ZWSP$_zmt_d"}"; done
    fi
    printf -v "$1" '%s' "$_zmt"
}

# zb_md_line_v <var> <text> — zb_md_text_v on one line: CR and LF as spaces.
zb_md_line_v() { local _zml="${2//$'\r'/ }"; zb_md_text_v "$1" "${_zml//$'\n'/ }"; }

# zb_md_cell_v <var> <text> — <text> in a table cell that keeps the table a
# table: one line, \ and | escaped, the rest as written (a cell read in a
# terminal stays plain).
zb_md_cell_v() {
    local _zmc="${2//$'\r'/ }"; _zmc="${_zmc//$'\n'/ }"; _zmc="${_zmc//\\/\\\\}"
    printf -v "$1" '%s' "${_zmc//|/\\|}"
}

# zb_md_inline_v <var> <text> — <text> on one line that opens no code span:
# backticks escaped, the rest as written (text for a model or a banner).
zb_md_inline_v() {
    local _zmi="${2//$'\r'/ }"; _zmi="${_zmi//$'\n'/ }"
    printf -v "$1" '%s' "${_zmi//\`/\\\`}"
}

# zb_md_fence_v <var> <text> — a fence <text> cannot close: one backtick more
# than its longest run of backticks, three at least.
zb_md_fence_v() {
    local _zmf="$2" _zmf_f='```'
    local -i _zmf_n=2
    while [[ "$_zmf" =~ \`+ ]]; do
        (( ${#BASH_REMATCH[0]} > _zmf_n )) && _zmf_n=${#BASH_REMATCH[0]}
        _zmf="${_zmf#*"${BASH_REMATCH[0]}"}"
    done
    while (( ${#_zmf_f} <= _zmf_n )); do _zmf_f+='`'; done
    printf -v "$1" '%s' "$_zmf_f"
}

# zb_ansi_strip_v <var> <text> — <text> with its terminal escapes taken out:
# ESC [ … a letter or ~ (colour, cursor), and ESC with one character after it.
zb_ansi_strip_v() {
    local LC_ALL=C _zma="$2" _zma_csi=$'\e''\[[0-9;?]*[a-zA-Z~]' _zma_one=$'\e''.'
    if [[ "$_zma" == *$'\e'* ]]; then
        while [[ "$_zma" =~ $_zma_csi ]]; do _zma="${_zma/"${BASH_REMATCH[0]}"/}"; done
        while [[ "$_zma" =~ $_zma_one ]]; do _zma="${_zma/"${BASH_REMATCH[0]}"/}"; done
        _zma="${_zma//$'\e'/}"
    fi
    printf -v "$1" '%s' "$_zma"
}
