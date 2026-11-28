#!/usr/bin/env bash
# scripts/lib/json-text.sh — the one place the shell writes or reads a JSON
# string (ADR-065 §5: asked on hot paths, so no process). jq is the reference:
# a string is written exactly as jq writes it, and read back from whatever jq,
# or this file, wrote. Anything bigger than a string — an object, a filter —
# is jq's.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JSON_TEXT_LOADED:-}" ]] && return 0
_ZBUILD_JSON_TEXT_LOADED=1

# zb_json_str_v <var> <text> — <text> as a JSON string, quotes included,
# spelled as jq spells it: \" and \\, \b \f \n \r \t, \u00XX for any other
# byte below 0x20 and for DEL; every other byte as it is (valid UTF-8 text is
# what jq writes too).
zb_json_str_v() {
    local LC_ALL=C _zjs="$2" _zjs_c _zjs_e
    local -i _zjs_i
    _zjs="${_zjs//\\/\\\\}"; _zjs="${_zjs//\"/\\\"}"
    if [[ "$_zjs" == *[$'\x01'-$'\x1f'$'\x7f']* ]]; then
        _zjs="${_zjs//$'\n'/\\n}"; _zjs="${_zjs//$'\t'/\\t}"; _zjs="${_zjs//$'\r'/\\r}"
        _zjs="${_zjs//$'\b'/\\b}"; _zjs="${_zjs//$'\f'/\\f}"
        for _zjs_i in {1..31} 127; do
            printf -v _zjs_c '%02x' "$_zjs_i"; printf -v _zjs_c "\\x$_zjs_c"
            [[ "$_zjs" == *"$_zjs_c"* ]] || continue
            printf -v _zjs_e '\\u%04x' "$_zjs_i"
            _zjs="${_zjs//"$_zjs_c"/"$_zjs_e"}"
        done
    fi
    printf -v "$1" '"%s"' "$_zjs"
}

# _zb_json_utf8_v <var> <code point> — the code point's UTF-8 bytes, built by
# hand so the locale does not matter. NUL cannot be held in a shell string and
# is left out.
_zb_json_utf8_v() {
    local -n _zj8_out="$1"; local -i _zj8_c="$2"; local _zj8_f
    _zj8_out=""
    if (( _zj8_c == 0 )); then return 0
    elif (( _zj8_c < 0x80 )); then printf -v _zj8_f '\\x%02x' "$_zj8_c"
    elif (( _zj8_c < 0x800 )); then printf -v _zj8_f '\\x%02x\\x%02x' $(( 0xC0 | _zj8_c >> 6 )) $(( 0x80 | _zj8_c & 0x3F ))
    elif (( _zj8_c < 0x10000 )); then
        printf -v _zj8_f '\\x%02x\\x%02x\\x%02x' $(( 0xE0 | _zj8_c >> 12 )) $(( 0x80 | (_zj8_c >> 6) & 0x3F )) $(( 0x80 | _zj8_c & 0x3F ))
    else
        printf -v _zj8_f '\\x%02x\\x%02x\\x%02x\\x%02x' $(( 0xF0 | _zj8_c >> 18 )) $(( 0x80 | (_zj8_c >> 12) & 0x3F )) \
            $(( 0x80 | (_zj8_c >> 6) & 0x3F )) $(( 0x80 | _zj8_c & 0x3F ))
    fi
    printf -v _zj8_out "$_zj8_f"
}

# zb_json_unescape_v <var> <body> — a JSON string's body (what lies between its
# quotes) as the text it stands for. One pass, left to right, so an escaped
# backslash is never read as the start of another escape: \" \\ \/ \b \f \n \r
# \t, and \uXXXX (a surrogate pair as one character). An escape JSON does not
# have is kept as written.
zb_json_unescape_v() {
    local LC_ALL=C _zju_r="$2" _zju_o="" _zju_p _zju_c _zju_h _zju_ch
    local -i _zju_cp _zju_lo
    while [[ "$_zju_r" == *\\* ]]; do
        _zju_p="${_zju_r%%\\*}"; _zju_o+="$_zju_p"; _zju_r="${_zju_r:${#_zju_p}+1}"
        _zju_c="${_zju_r:0:1}"; _zju_r="${_zju_r:1}"
        case "$_zju_c" in
            '"') _zju_o+='"' ;;  '\') _zju_o+='\' ;;  '/') _zju_o+='/' ;;
            b) _zju_o+=$'\b' ;;  f) _zju_o+=$'\f' ;;  n) _zju_o+=$'\n' ;;  r) _zju_o+=$'\r' ;;  t) _zju_o+=$'\t' ;;
            u)
                _zju_h="${_zju_r:0:4}"
                if [[ "$_zju_h" =~ ^[0-9a-fA-F]{4}$ ]]; then
                    _zju_cp=$(( 16#$_zju_h )); _zju_r="${_zju_r:4}"
                    if (( _zju_cp >= 0xD800 && _zju_cp <= 0xDBFF )) && [[ "${_zju_r:0:6}" =~ ^\\u([dD][c-fC-F][0-9a-fA-F]{2})$ ]]; then
                        _zju_lo=$(( 16#${BASH_REMATCH[1]} )); _zju_r="${_zju_r:6}"
                        _zju_cp=$(( 0x10000 + ((_zju_cp - 0xD800) << 10) + (_zju_lo - 0xDC00) ))
                    fi
                    _zb_json_utf8_v _zju_ch "$_zju_cp"; _zju_o+="$_zju_ch"
                else
                    _zju_o+='\u'
                fi ;;
            *) _zju_o+="\\$_zju_c" ;;
        esac
    done
    printf -v "$1" '%s' "$_zju_o$_zju_r"
}

# ZB_JSON_STR_RE — a JSON string's body, for a bash regex that finds a string
# in JSON text (two groups: the body, and its last unit). Read the body with
# zb_json_unescape_v.
# shellcheck disable=SC2034  # read by the files that source this one
ZB_JSON_STR_RE='(([^"\\]|\\.)*)'

# zb_json_strings_v <array var> <json> — each string in <json> (an array of
# strings, as jq -c writes it), whole and read back, into the array.
zb_json_strings_v() {
    local -n _zjsa="$1"; local LC_ALL=C _zjs_j="$2" _zjs_s _zjs_re='^[^"]*"'"$ZB_JSON_STR_RE"'"'
    _zjsa=()
    while [[ "$_zjs_j" =~ $_zjs_re ]]; do
        zb_json_unescape_v _zjs_s "${BASH_REMATCH[1]}"; _zjsa+=("$_zjs_s")
        _zjs_j="${_zjs_j:${#BASH_REMATCH[0]}}"
    done
}
