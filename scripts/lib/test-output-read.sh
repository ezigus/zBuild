#!/usr/bin/env bash
# scripts/lib/test-output-read.sh — the one reader of a suite's output (ADR-054,
# amended 2026-11-20, #2573).
#
# A suite reports each file that did not pass as `<suite>: FAIL <path>` or
# `<suite>: TIMEOUT <path> (…)`, and each tier as `<suite>: N/M passed`. Every
# stage that reads those lines reads them here: on #1764 run 44782866204 the
# test stage's own pattern `^[a-z]+: (FAIL|TIMEOUT)` dropped `e2e: FAIL …` (a
# digit in the name) and every relative path, and two failing tests reached no
# stage in either round.
#
# The read is forgiving: any suite name of letters, digits, `-` and `_`; FAIL
# or TIMEOUT in any case; colour codes, carriage returns, leading spaces and
# list or ✗ markers set aside; the path absolute under any spelling of the
# staging folder (as given, `pwd -L`, `pwd -P`, a doubled slash) or relative to
# the repository.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_OUTPUT_READ_LOADED:-}" ]] && return 0
_ZBUILD_TEST_OUTPUT_READ_LOADED=1

# The canonical lines zb_test_output_normalize writes, for a reader's block
# logic. A marker that names a file has the file as its third word; one that
# names none has its words in brackets, `lint: FAIL (npm run lint)`.
# shellcheck disable=SC2034  # read by the sourcing readers
ZB_TEST_MARKER_ERE='^[A-Za-z0-9_-]+: (FAIL|TIMEOUT) '
# shellcheck disable=SC2034
ZB_TEST_MARKER_FILE_ERE='^[A-Za-z0-9_-]+: (FAIL|TIMEOUT) [^(]'
# shellcheck disable=SC2034
ZB_TEST_TALLY_ERE='^[A-Za-z0-9_-]+: [0-9]+/[0-9]+ passed'

# zb_test_output_normalize <raw> [staging_dir] — the output with colour codes
# and carriage returns gone, and every marker and tally line in its canonical
# form: `<suite>: FAIL|TIMEOUT <file>[ <rest>]` and `<suite>: N/M passed[…]`.
# With <staging_dir>, a path under it is written relative to it, and a path
# that names no file of the repository is put in brackets. Other lines are
# kept as they are.
zb_test_output_normalize() {
    local raw="${1:-}" tmp="${2:-}" tl="" tp=""
    if [[ -n "$tmp" ]]; then
        tmp="${tmp%/}"
        tl="$(cd "$tmp" 2>/dev/null && pwd -L)" || tl=""
        tp="$(cd "$tmp" 2>/dev/null && pwd -P)" || tp=""
    fi
    LC_ALL=C awk -v t="$tmp" -v tl="$tl" -v tp="$tp" '
        function under(p, base) {
            return base != "" && index(p, base "/") == 1 ? substr(p, length(base) + 2) : ""
        }
        function strip(p,   q, i, r) {
            q = p; gsub(/\/\/+/, "/", q)
            for (i = 1; i <= nb; i++) {
                if ((r = under(p, b[i])) != "") return r
                if ((r = under(q, b[i])) != "") return r
            }
            return p
        }
        BEGIN {
            nb = 0
            if (t  != "") { b[++nb] = t; c = t; gsub(/\/\/+/, "/", c); b[++nb] = c }
            if (tl != "") b[++nb] = tl
            if (tp != "") b[++nb] = tp
        }
        {
            gsub(/\033\[[0-9;?]*[A-Za-z~]/, ""); gsub(/\r/, "")
            s = $0
            while (sub(/^([ \t]+|\*|>|\||- |✗|✘|✖|•)/, "", s)) {}
            if (match(s, /^[A-Za-z0-9_-]+:[ \t]+/)) {
                suite = s; sub(/:.*/, "", suite)
                rest = substr(s, RLENGTH + 1)
                verb = rest; sub(/[ \t].*/, "", verb); uv = toupper(verb)
                if (uv == "FAIL" || uv == "TIMEOUT") {
                    rest = substr(rest, length(verb) + 1); sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
                    if (t != "") { r = strip(rest); if (r != rest) { rest = r; sub(/^\/+/, "", rest) } }
                    path = rest; sub(/[ \t].*/, "", path)
                    file = (path != "" && path !~ /^\(/ && path !~ /(^|\/)\.\.(\/|$)/ && (path ~ /\// || path ~ /\.[A-Za-z0-9]+$/))
                    if (file && t != "" && substr(path, 1, 1) == "/") file = 0
                    if (rest == "" || file || rest ~ /^\(/) print suite ": " uv (rest == "" ? "" : " " rest)
                    else print suite ": " uv " (" rest ")"
                    next
                }
                if (match(rest, /^[0-9]+\/[0-9]+[ \t]+[Pp][Aa][Ss][Ss][Ee][Dd]/)) {
                    nm = rest; sub(/[ \t].*/, "", nm)
                    tail = substr(rest, RLENGTH + 1)
                    print suite ": " nm " passed" tail
                    next
                }
            }
            print
        }' <<< "$raw" 2>/dev/null || printf '%s\n' "$raw"
}

# zb_test_output_failing_files <raw> [staging_dir] — every file a marker names,
# one per line, sorted and unique: relative to <staging_dir> when given, else
# as the suite printed it.
zb_test_output_failing_files() {
    local norm
    norm="$(zb_test_output_normalize "${1:-}" "${2:-}")"
    LC_ALL=C awk -v re="$ZB_TEST_MARKER_FILE_ERE" '$0 ~ re { print $3 }' <<< "$norm" 2>/dev/null \
        | LC_ALL=C sort -u || true
}

# zb_test_output_tally <raw> <suite> — the last `N/M` the suite reported for
# <suite> (`mutation: 25/25 passed` → 25/25), or nothing.
zb_test_output_tally() {
    local norm
    norm="$(zb_test_output_normalize "${1:-}")"
    LC_ALL=C awk -v re="$ZB_TEST_TALLY_ERE" -v s="${2:-}" '
        $0 ~ re && index($0, s ": ") == 1 { n = $2 } END { if (n != "") print n }' <<< "$norm" 2>/dev/null || true
}
