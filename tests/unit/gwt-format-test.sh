#!/usr/bin/env bash
# tests/unit/gwt-format-test.sh — a requirement is written as Given/When/Then
# under its first line, and every stage reads it so (#2467, ADR-073 §1–§4 §7 §8).
#
# Why: on #1805 run 41757933766 design passed BNDY-1 ("the test file contains
# both a resume-side assertion and a fresh-run sub-case") and DLGT-1 (two
# behaviours and a sentinel in one SPEC). test-author used all three of its
# tries on them: a SPEC that is not one observable behaviour cannot be proven
# by its test, and nothing caught it where it was written.
#
# P1 a SPEC with parts is one SPEC: its id once, its words and covers: from its
#    first line, its evidence too
# P2 its parts, in order, labelled — And continues the part above it
# P3 a SPEC with no parts still reads as before
# P4 a part wrapped onto the next line is one part
# P5 a SPEC is shown with its parts
# C1 design's check refuses a [code] or [done] SPEC with no parts, in plain words
#    that show the form; a [no-code] one may have none
# C2 ...one with no When, or two, or an And straight after the When
# C3 ...one with no Then, or an empty part
# C4 ...a part outside any SPEC, or under a REMOVED line
# C5 a SPEC with its parts in order passes
# D1 design's prompt shows the form, with Cleanup, and says to rewrite a
#    one-line SPEC it keeps
# R1 issue-acceptance, the review lenses and build are shown each SPEC's parts
# R2 the run-status words of a SPEC are its first line only
# B1 build is told the three ways to deal with a test that leaves something behind
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "requirements are written as Given/When/Then (#2467)"
setup_test_env "gwt-format"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/scripts" "$R/tests"
( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t \
    && printf 'run_guard() { :; }\n' > scripts/x.sh && git add -A && git commit -qm base ) >/dev/null 2>&1
D="$TEST_TEMP_DIR/design.md"
_design() {  # the acceptance block's lines → design.md
    { printf '# Design\n\n```scope\nscripts/x.sh\n```\n\n```acceptance\n'
      printf '%s\n' "$@"
      printf 'WIRING: none\nTESTFILES:\nFRSH-1: tests/a-test.sh\nLOOP-1: tests/a-test.sh\n```\n'; } > "$D"
}
_gwt() {  # the C10 violations of the design's checks
    _design_checks "$D" "$R" "" >/dev/null 2>&1
    local v; for v in "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}"; do [[ "$v" == GWT_* ]] && printf '%s\n' "$v"; done
}
_plain() { local v; while IFS= read -r v; do [[ -n "$v" ]] && _dck_plain "$v" && printf '\n'; done <<< "$1"; }

GOOD=(
'FRSH-1[code]: a new run starts from the first stage covers: RESU-1'
'  Given: a run whose stages all completed'
'  When: it is started again without --resume'
'  Then: every stage is dispatched, starting with the first'
'  And: no stage is skipped'
'  Cleanup: the run state folder is gone'
'GARD-1[done]: a resumed run reads the saved round evidence: scripts/x.sh:"run_guard()"'
'  Given: a run stopped in round 2'
'  When: it is resumed'
'  Then: it starts in round 2'
'LOOP-1[code]: a nested loop starts at round 1'
'  When: an inner loop is entered again,'
'    while the outer loop goes round'
'  Then: the inner loop is at round 1'
'DOCS-1[no-code]: the README says how to resume'
)

print_test_section "P1-P5: reading a SPEC"
_design "${GOOD[@]}"
assert_eq "[P1] each SPEC once" "FRSH-1 GARD-1 LOOP-1 DOCS-1" "$(acceptance_list_spec_ids "$D" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "[P1] its words are its first line" "a new run starts from the first stage" "$(acceptance_spec_text "$D" FRSH-1)"
assert_eq "[P1] ...and so is covers:" "RESU-1" "$(acceptance_spec_covers "$D" FRSH-1)"
assert_eq "[P1] ...and evidence:" 'scripts/x.sh:"run_guard()"' "$(acceptance_spec_evidence "$D" GARD-1)"
_blk="$(extract_acceptance_block "$D")"
_p=(); acceptance_spec_parts_v _p "$_blk" FRSH-1
assert_eq "[P2] its parts in order, labelled; And continues the Then" \
    "Given 1|a run whose stages all completed;When|it is started again without --resume;Then 1|every stage is dispatched, starting with the first;Then 2|no stage is skipped;Cleanup 1|the run state folder is gone" \
    "$(printf '%s;' "${_p[@]}" | tr '\t' '|' | sed 's/;$//')"
_p=(); acceptance_spec_parts_v _p "$_blk" DOCS-1
assert_eq "[P3] a SPEC with no parts has none" "0" "${#_p[@]}"
assert_eq "[P3] ...and its words read as before" "the README says how to resume" "$(acceptance_spec_text "$D" DOCS-1)"
_p=(); acceptance_spec_parts_v _p "$_blk" LOOP-1
assert_eq "[P4] a wrapped part is one part" "When|an inner loop is entered again, while the outer loop goes round" "$(tr '\t' '|' <<< "${_p[0]:-}")"
_r=""; acceptance_spec_render_v _r "$_blk" FRSH-1
assert_contains "[P5] a SPEC is shown with its words" "$_r" "a new run starts from the first stage"
# #2470 (ADR-073 §2): by the word design wrote, never a number.
assert_contains "[P5] ...and each part, as written" "$_r" "  And: no stage is skipped"
assert_eq "[P5] ...never numbered" "0" "$(grep -c 'Then [0-9]' <<< "$_r")"

print_test_section "C1-C5: design's check of the parts (C10)"
_design "${GOOD[@]}"
assert_eq "[C5] a SPEC with its parts in order passes" "" "$(_gwt)"
_design 'FRSH-1[code]: a new run starts from the first stage' 'DOCS-1[no-code]: the README says how to resume'
_v="$(_gwt)"
assert_contains "[C1] a [code] SPEC with no parts is refused" "$_v" "GWT_MISSING FRSH-1"
assert_not_contains_line() { if grep -q -- "$3" <<< "$2"; then assert_fail "$1" "$2"; else assert_pass "$1"; fi; }
assert_not_contains_line "[C1] ...a [no-code] one may have none" "$_v" "DOCS-1"
assert_contains "[C1] ...in plain words that show the form" "$(_plain "$_v")" "When:"
_design 'GARD-1[done]: the guard runs evidence: scripts/x.sh:"run_guard()"'
assert_contains "[C1] a [done] SPEC with no parts is refused" "$(_gwt)" "GWT_MISSING GARD-1"
_design 'FRSH-1[code]: x' '  Given: a run' '  Then: it starts'
assert_contains "[C2] no When" "$(_gwt)" "GWT_NO_WHEN FRSH-1"
_design 'FRSH-1[code]: x' '  When: it starts' '  When: it stops' '  Then: it ran'
_v="$(_gwt)"
assert_contains "[C2] two Whens" "$_v" "GWT_MANY_WHEN FRSH-1"
assert_contains "[C2] ...said as one action per SPEC" "$(_plain "$_v")" "one When"
_design 'FRSH-1[code]: x' '  When: it starts' '  And: it stops' '  Then: it ran'
assert_contains "[C2] an And straight after the When" "$(_gwt)" "GWT_AND_AFTER_WHEN FRSH-1"
_design 'FRSH-1[code]: x' '  Given: a run' '  When: it starts'
assert_contains "[C3] no Then" "$(_gwt)" "GWT_NO_THEN FRSH-1"
_design 'FRSH-1[code]: x' '  When: it starts' '  Then:'
assert_contains "[C3] an empty part" "$(_gwt)" "GWT_EMPTY_PART FRSH-1 Then 1"
_design '  Given: a stray part' 'FRSH-1[code]: x' '  When: it starts' '  Then: it ran'
_v="$(_gwt)"
assert_contains "[C4] a part outside any SPEC" "$_v" "GWT_ORPHAN_PART"
assert_contains "[C4] ...said in plain words, naming the line (review on #2469)" "$(_plain "$_v")" "(Given: a stray part) —"
_design 'FRSH-1[code]: x' '  When: it starts' '  Then: it ran' 'REMOVED: FRSH-2 — merged into FRSH-1' '  Then: something'
assert_contains "[C4] a part under a REMOVED line" "$(_gwt)" "GWT_PART_ON_REMOVED FRSH-2"

print_test_section "D1: design's prompt"
_dp="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/plugins/agent/design/plugin.sh")"
for _w in "Given: " "When: " "Then: " "And: " "Cleanup: "; do
    assert_contains "[D1] the prompt shows $_w" "$_dp" "$_w"
done
assert_contains "[D1] one When per SPEC" "$_dp" "exactly one When"
assert_contains "[D1] Cleanup only for what outlives the test" "$_dp" "outlives the test"
# #2470: the kept one-line SPECs are named (judge-feedback-test.sh F1).
assert_contains "[D1] a one-line SPEC it keeps is rewritten" "$_dp" "is rewritten with its parts"

print_test_section "R1-R2: the readers"
_design "${GOOD[@]}"
_ia="$(acceptance_requirements_for_judge "$D")"
assert_contains "[R1] issue-acceptance is shown the parts" "$_ia" "When: it is started again without --resume"
(
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" >/dev/null 2>&1
    _rl_requirements_readable "$D"
) > "$TEST_TEMP_DIR/lens.txt" 2>/dev/null
assert_contains "[R1] a review lens is shown the parts" "$(cat "$TEST_TEMP_DIR/lens.txt")" "And: no stage is skipped"
(
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    _build_gather_acceptance_specs "$D"
) > "$TEST_TEMP_DIR/build.txt" 2>/dev/null
assert_contains "[R1] build is shown the parts" "$(cat "$TEST_TEMP_DIR/build.txt")" "When: it is started again without --resume"
assert_eq "[R1] ...one line per SPEC still" "3" "$(grep -c . "$TEST_TEMP_DIR/build.txt")"
assert_eq "[R2] a SPEC's words for the status comment are its first line" \
    "a new run starts from the first stage" "$(acceptance_spec_text "$D" FRSH-1)"

print_test_section "B1: build and a test that leaves something behind"
_bp="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/plugins/agent/build/lib/prompt.sh")"
assert_contains "[B1] its code leaks: it writes where it is told" "$_bp" "write where it is told"
assert_contains "[B1] the code is meant to leave something: the test is wrong, needs cleanup" "$_bp" "the test is wrong: <test file>: needs cleanup of"
assert_contains "[B1] every test needs it: the shared test helpers" "$_bp" "shared test helpers"

cleanup_test_env
print_test_results
