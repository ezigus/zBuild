#!/usr/bin/env bash
# scripts/lib/test-output-read.sh — the one reader of a suite's output (ADR-054,
# amended 2026-11-20, #2573).
#
# scripts/run-tests.sh reports each file that did not pass as
# `<suite>: FAIL <path>` or `<suite>: TIMEOUT <path> (…)`, and each tier as
# `<suite>: N/M passed`, at column 0. Every stage that reads those lines reads
# them here: on #1764 run 44782866204 the test stage's own pattern
# `^[a-z]+: (FAIL|TIMEOUT)` dropped `e2e: FAIL …` (a digit in the name) and
# every relative path, and two failing tests reached no stage in either round.
#
# Loose only where the output really varies: any suite name of letters,
# digits, `-` and `_`; colour codes and carriage returns set aside; a path
# absolute under a spelling of the staging folder (as given, `pwd -L`,
# `pwd -P`, a doubled slash) or relative to the repository. The verb is the
# uppercase word run-tests.sh writes, at column 0: an indented `unit: FAIL …`
# is a nested run's output, and `✗ NC-G: timeout …` is a check's name.
# A path under another alias of the staging folder (a second symlink to it)
# is not recognised and names no file — a known gap, left as low priority.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_OUTPUT_READ_LOADED:-}" ]] && return 0
_ZBUILD_TEST_OUTPUT_READ_LOADED=1

# The canonical lines zb_test_output_normalize writes, for a reader's block
# logic. A marker that names a file is `<suite>: <VERB> <file>`, then a tab and
# the rest of the line when there is one (`(exceeded 480s, rc=124)`); one that
# names none has its words in brackets, `lint: FAIL (npm run lint)`.
# zb_test_output_marker_file_awk (below) takes the file out of the line.
# shellcheck disable=SC2034  # read by the sourcing readers
ZB_TEST_MARKER_ERE='^[A-Za-z0-9_-]+: (FAIL|TIMEOUT)( |$)'
# shellcheck disable=SC2034
ZB_TEST_MARKER_FILE_ERE='^[A-Za-z0-9_-]+: (FAIL|TIMEOUT) [^(]'
# shellcheck disable=SC2034
ZB_TEST_TALLY_ERE='^[A-Za-z0-9_-]+: [0-9]+/[0-9]+ passed'
# Any column-0 `<name>: ` line — a runner's own line, a tool's `jq: error …`:
# it ends the message of the check before it.
# shellcheck disable=SC2034
ZB_TEST_NAMED_LINE_ERE='^[A-Za-z0-9_-]+: '
# An awk function a reader pastes into its program: the file of a canonical
# marker line that names one (the text after `<suite>: <VERB> `, up to a tab).
# shellcheck disable=SC2034
ZB_TEST_MARKER_FILE_AWK='function zb_marker_file(l) { sub(/^[^:]*: [A-Z]+ /, "", l); sub(/\t.*/, "", l); return l }'

# zb_test_output_normalize <raw> [staging_dir] — the output with colour codes
# and carriage returns gone, and every marker line in its canonical form.
# With <staging_dir>, a path under it is written relative to it, and a path
# that is not a file there (`[[ -f ]]`) is put in brackets. Other lines are
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
        function sq(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
        # A file of the repository: one `test -f` a distinct path (a marker
        # names a failing file, so there are few).
        function isfile(p) {
            if (!(p in known)) known[p] = (system("test -f " sq(t "/" p)) == 0)
            return known[p]
        }
        BEGIN {
            nb = 0
            if (t  != "") { b[++nb] = t; c = t; gsub(/\/\/+/, "/", c); b[++nb] = c }
            if (tl != "") b[++nb] = tl
            if (tp != "") b[++nb] = tp
        }
        {
            gsub(/\033\[[0-9;?]*[A-Za-z~]/, ""); gsub(/\r/, "")
            if (!match($0, /^[A-Za-z0-9_-]+: (FAIL|TIMEOUT)( |$)/)) { print; next }
            head = $0; sub(/: .*/, "", head)
            verb = substr($0, length(head) + 3); sub(/ .*/, "", verb)
            rest = substr($0, length(head) + length(verb) + 4); sub(/^ +/, "", rest); sub(/[ \t]+$/, "", rest)
            more = ""
            if (rest !~ /^\(/ && match(rest, / \([^()]*\)$/)) { more = substr(rest, RSTART + 1); rest = substr(rest, 1, RSTART - 1) }
            if (t != "") { r = strip(rest); if (r != rest) { rest = r; sub(/^\/+/, "", rest) } }
            file = (rest != "" && rest !~ /^\(/ && rest !~ /(^|\/)\.\.(\/|$)/)
            if (file && t != "") file = (substr(rest, 1, 1) != "/" && isfile(rest))
            else if (file) file = (rest ~ /\// || rest ~ /\.[A-Za-z0-9]+$/)
            if (file) print head ": " verb " " rest (more == "" ? "" : "\t" more)
            else if (rest == "" && more == "") print head ": " verb
            else if (rest ~ /^\(/) print head ": " verb " " rest (more == "" ? "" : " " more)
            else print head ": " verb " (" rest (more == "" ? "" : " " more) ")"
        }' <<< "$raw" 2>/dev/null || printf '%s\n' "$raw"
}

# zb_test_output_failing_files <raw> [staging_dir] — every file a marker names,
# one per line, sorted and unique: relative to <staging_dir> when given, else
# as the suite printed it.
zb_test_output_failing_files() {
    local norm
    norm="$(zb_test_output_normalize "${1:-}" "${2:-}")"
    LC_ALL=C awk -v re="$ZB_TEST_MARKER_FILE_ERE" "$ZB_TEST_MARKER_FILE_AWK"'
        $0 ~ re { print zb_marker_file($0) }' <<< "$norm" 2>/dev/null \
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
