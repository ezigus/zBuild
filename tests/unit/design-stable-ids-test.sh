#!/usr/bin/env bash
# tests/unit/design-stable-ids-test.sh — a SPEC's id describes it and never
# moves, and a [done] SPEC is done on the code from before the change (#2462,
# ADR-069 §1, §2).
#
# Why: on #1805 run 41582195372 design's SPECs named requirement numbers that
# had moved, and design marked the core of the issue [done] with evidence in
# code last run's build wrote on the reused branch — a [done] SPEC has no test
# and the old-code check skips it, so the main behaviour would ship untested.
# Its evidence was a line number, which moved from 3808 to 3896 between tries.
#
# D1  [code] a new design's bare SPEC code is refused, in plain words
# D2  [code] a duplicate id, and a line shaped like an id with a bad code, are
#            refused
# D3  [code] an id the last design had is kept, or listed `REMOVED: <id> — <why>`
# D4  [code] a removed id never comes back and stays listed as removed
# D5  [code] a new id's number is one more than its code's highest, removed
#            ones counted — never lower, never skipping one
# D6  [code] a SPEC code that is a requirement's code is refused
# D7  [code] a SPEC id the issue's own text writes is refused
# D8  [code] the last design's old SPEC-n ids need no REMOVED line
# D9  [code] [done] evidence with a line number is refused: lines move
# D10 [code] [done] evidence `file:"text"` passes when the text is in the file
#            on the base commit and outside what this branch changed
# D11 [code] text only in lines this branch added or changed is refused
# D12 [code] text not in the file is refused
# D13 [code] a test file named alone passes; a source file named alone is
#            refused (name a piece of its text)
# D14 [code] with no base commit, the text in the file is enough
# D15 [code] a REMOVED line may name a SPEC a failed try of this run wrote (#2482)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "SPEC ids describe their item; [done] is proven on the code from before (#2462)"
setup_test_env "design-stable-ids"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"
set +e

# A repository whose main holds scripts/run.sh; the work branch adds a line.
ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$ROOT/scripts" "$ROOT/tests/unit"
git -C "$ROOT" init -q -b main
printf 'run() {\n    echo old guard\n}\n' > "$ROOT/scripts/run.sh"
printf 'assert ok\n' > "$ROOT/tests/unit/run-test.sh"
git -C "$ROOT" add -A && git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qm base
git -C "$ROOT" checkout -qb work
printf 'run() {\n    echo old guard\n    echo new skip guard\n}\n' > "$ROOT/scripts/run.sh"
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qam work

REQ="$TEST_TEMP_DIR/requirements.json"
printf '%s' '{"requirements":[{"id":"RSUM-1","text":"resume"}],"removed":[{"id":"GONE-1","text":"x","reason":"y"}]}' > "$REQ"
ISSUE="$TEST_TEMP_DIR/issue.txt"; printf 'Fix resume. See LBL-1 in the old notes.\n' > "$ISSUE"
PREV="$TEST_TEMP_DIR/prev-design.md"; : > "$PREV"

_md() {   # <acceptance lines...> — a design with that acceptance block
    printf '# D\n\n```scope\nscripts/run.sh\n```\n\n```acceptance\n'
    printf '%s\n' "$@"
    printf 'WIRING: none\nTESTFILES:\n'
    printf '%s\n' "${BIND[@]}"
    printf '```\n'
}
BIND=("LOOP-1: tests/unit/run-test.sh")
_check() {   # <acceptance lines...> — runs the checks; $V = violations, $P = plain words
    _md "$@" > "$TEST_TEMP_DIR/design.md"
    _design_checks "$TEST_TEMP_DIR/design.md" "$ROOT" "$REQ" "$PREV" "$(<"$ISSUE")"
    V="$(printf '%s\n' "${_DESIGN_VIOLATIONS[@]}")"
    P="$(for _v in "${_DESIGN_VIOLATIONS[@]}"; do _dck_plain "$_v"; printf '\n'; done)"
}
_ok()  { if [[ -z "$V" ]]; then assert_pass "$1"; else assert_fail "$1" "violations: $V"; fi; }
_has() { assert_contains "$1" "$V" "$2"; }

# ── D1 / D2 ──────────────────────────────────────────────────────────────────
_check 'LOOP-1[code]: a resumed loop starts at its round covers: RSUM-1' '  When: it runs' '  Then: it is done'
_ok "[D1] a design with descriptive ids passes"
BIND=("SPEC-1: tests/unit/run-test.sh")
_check 'SPEC-1[code]: a resumed loop starts at its round covers: RSUM-1' '  When: it runs' '  Then: it is done'
_has "[D1] the bare SPEC code is refused" "ID_OLD_FORM SPEC-1"
assert_contains "[D1] ...in plain words that ask for a describing code" "$P" "describes"
BIND=("LOOP-1: tests/unit/run-test.sh")
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-1[no-code]: b'
_has "[D2] a duplicate id is refused" "ID_DUPLICATE LOOP-1"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOPING-1[no-code]: b'
_has "[D2] a line shaped like an id with a bad code is refused" "ID_BAD LOOPING-1"

# ── D3 / D4 / D5 ─────────────────────────────────────────────────────────────
_md 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-2[no-code]: b' 'REMOVED: LOOP-3 — the issue dropped it' > "$PREV"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'REMOVED: LOOP-3 — the issue dropped it'
_has "[D3] an id the last design had, dropped with no REMOVED line, is refused" "ID_DROPPED LOOP-2"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'REMOVED: LOOP-2 — folded into LOOP-1' 'REMOVED: LOOP-3 — the issue dropped it'
_ok "[D3] ...listed as REMOVED with why, it passes"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-2[no-code]: b' 'LOOP-3[no-code]: c'
_has "[D4] a removed id coming back is refused" "ID_REUSED LOOP-3"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-2[no-code]: b'
_has "[D4] a removed id no longer listed as removed is refused" "ID_REMOVED_LOST LOOP-3"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-2[no-code]: b' 'LOOP-4[no-code]: d' 'REMOVED: LOOP-3 — the issue dropped it'
_ok "[D5] a new id one past the code's highest (removed ones counted) passes"
_md 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' > "$PREV"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'LOOP-2[no-code]: b'
_has "[D5] a new number below the code's highest is refused" "ID_NOT_AFTER_LAST LOOP-2"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'LOOP-5[no-code]: e'
_has "[D5] a new number that skips one is refused (review #2463)" "ID_NOT_AFTER_LAST LOOP-5"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'LOOP-5[no-code]: e' 'LOOP-4[no-code]: d'
_ok "[D5] two new ones that follow on, in any order, pass"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'REMOVED: NEVR-1 — never there'
_has "[D3] a REMOVED line for an id the last design never had is refused (review #2463)" "ID_REMOVED_UNKNOWN NEVR-1"
# #2482: on #1805 run 42293991602 try 2 removed a SPEC only try 1 (failed) had,
# and the check refused the line — the try was lost to that alone. A try this
# run wrote that did not pass is in the try archive, its draft beside it.
_TRY="$TEST_TEMP_DIR/attempts/design/iter-3-attempt-2"; mkdir -p "$_TRY"
_md 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'TRYD-1[done]: d evidence: tests/unit/run-test.sh' > "$_TRY/design-draft.md"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'REMOVED: TRYD-1 — only a failed try had it'
_ok "[D15] a REMOVED line for a SPEC a failed try of this run wrote passes (#2482)"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'TRYD-1[no-code]: d'
_ok "[D15] ...and a SPEC the failed try had may simply be kept"
_RUN_MARK="$TEST_TEMP_DIR/run-start"; : > "$_RUN_MARK"; touch -t 200001010000 "$_TRY/design-draft.md"
ZBUILD_RUN_START_MARKER="$_RUN_MARK" _check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'LOOP-3[no-code]: c' 'REMOVED: TRYD-1 — only a failed try had it'
_has "[D15] a draft from before this run does not count" "ID_REMOVED_UNKNOWN TRYD-1"
rm -rf "$TEST_TEMP_DIR/attempts"
: > "$PREV"

# ── D6 / D7 / D8 ─────────────────────────────────────────────────────────────
BIND=("RSUM-2: tests/unit/run-test.sh")
_check 'RSUM-2[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done'
_has "[D6] a SPEC code that is a requirement's code is refused" "ID_OTHER_POOL RSUM-2"
BIND=("GONE-2: tests/unit/run-test.sh")
_check 'GONE-2[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done'
_has "[D6] ...a removed requirement's code too" "ID_OTHER_POOL GONE-2"
# #2476: a SPEC the last design already had keeps its id — ids never move. A
# requirement that took its code is new, and intake refuses it.
BIND=("RSUM-2: tests/unit/run-test.sh")
_md 'RSUM-2[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' > "$PREV"
_check 'RSUM-2[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done'
_ok "[D6] a SPEC the last design had keeps its id, though a requirement now shares its code"
: > "$PREV"
BIND=("LBL-1: tests/unit/run-test.sh")
_check 'LBL-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done'
_has "[D7] a SPEC id the issue's text writes is refused" "ID_IN_ISSUE LBL-1"
BIND=("LOOP-1: tests/unit/run-test.sh")
_md 'SPEC-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'SPEC-2[no-code]: b' > "$PREV"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done'
_ok "[D8] the last design's old SPEC-n ids need no REMOVED line"
: > "$PREV"

# ── D9–D13 ───────────────────────────────────────────────────────────────────
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: the old guard runs evidence: scripts/run.sh:2' '  When: it runs' '  Then: it is done'
_has "[D9] evidence with a line number is refused" "DONE_LINE_EVIDENCE GARD-1 scripts/run.sh:2"
assert_contains "[D9] ...saying line numbers move" "$P" "move"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: the old guard runs evidence: scripts/run.sh:"echo old guard"' '  When: it runs' '  Then: it is done'
_ok "[D10] text on the base commit, outside this branch's change, passes"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: the skip guard runs evidence: scripts/run.sh:"echo new skip guard"' '  When: it runs' '  Then: it is done'
_has "[D11] text only in lines this branch added is refused" "DONE_NOT_BEFORE GARD-1"
assert_contains "[D11] ...saying to make it [code] with a test" "$P" "[code]"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: x evidence: scripts/run.sh:"no such text"' '  When: it runs' '  Then: it is done'
_has "[D12] text not in the file is refused" "DONE_TEXT_MISSING GARD-1"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: x evidence: tests/unit/run-test.sh' '  When: it runs' '  Then: it is done'
_ok "[D13] a test file named alone passes"
_check 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: x evidence: scripts/run.sh' '  When: it runs' '  Then: it is done'
_has "[D13] a source file named alone is refused" "DONE_NO_TEXT GARD-1"

# ── D14 ──────────────────────────────────────────────────────────────────────
NOGIT="$TEST_TEMP_DIR/nogit"; mkdir -p "$NOGIT/scripts" "$NOGIT/tests/unit"
cp "$ROOT/scripts/run.sh" "$NOGIT/scripts/run.sh"; cp "$ROOT/tests/unit/run-test.sh" "$NOGIT/tests/unit/"
_md 'LOOP-1[code]: a covers: RSUM-1' '  When: it runs' '  Then: it is done' 'GARD-1[done]: x evidence: scripts/run.sh:"echo new skip guard"' '  When: it runs' '  Then: it is done' > "$TEST_TEMP_DIR/design.md"
_design_checks "$TEST_TEMP_DIR/design.md" "$NOGIT" "$REQ" "$PREV" "$(<"$ISSUE")"
assert_eq "[D14] with no base commit, the text in the file is enough" "" "$(printf '%s' "${_DESIGN_VIOLATIONS[*]}")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
