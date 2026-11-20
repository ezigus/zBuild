#!/usr/bin/env bash
# tests/unit/design-refines-newest-try-test.sh — design refines its newest try,
# and "its last good output" is the newest passing output (#2569 R4, ADR-068 §8).
#
# Why: on #1764 run 44530053809, "YOUR LATEST DESIGN" inlined the last design
# that passed, while the working copy — the newer, rejected try — was only a
# path. Try i1a12 re-added, word for word, a step the working copy had removed.
# And "its last good output" pointed at iter-3-attempt-1 (11-17) instead of the
# newer iter-2-attempt-9 (11-19): it was chosen by iteration number.
#
# N1 [change] after a rejected try, YOUR LATEST DESIGN is the working copy, in full
# N2 [change] the last passing design is shown under its own heading, as
#             reference only: do not copy back what the newest try removed
# N3 [guard]  after a try that passed (no working copy left), YOUR LATEST DESIGN
#             is design.md and no reference section is added
# N4 [change] "its last good output" is the newest passing attempt by the time
#             the attempt archive recorded, not the highest iteration number
# N5 [change] after a try whose call was cut off (rc 124) part-way through the
#             working copy, YOUR LATEST DESIGN is the last design that passed;
#             the unfinished try is shown after it, and the working copy the
#             call writes starts as the last design that passed (#2569 review)
# N6 [change] a working copy with no acceptance block is an unfinished try too,
#             even when its call ended normally
# N7 [change] the opening sentence says what is shown: it never says the last
#             design that passed is shown when no design has passed
# N8 [change] a working copy design's last result never judged (that result is
#             a pass: the stage stopped during the call) is an unfinished try
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design refines its newest try; the last good output is the newest (#2569 R4)"
setup_test_env "design-refines-newest-try"
unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; return 0; }

BT='```'
REMOVED_STEP="- Add core/claim/claim.sh to config/shape-change-paths.txt | areas: config/shape-change-paths.txt"
PASSED="# Design (the one that passed)

${BT}steps
- Create core/claim/claim.sh | areas: core/claim/claim.sh
${REMOVED_STEP}
${BT}

${BT}acceptance
DSWORK-1[no-code]: the docs say so
WIRING: none
TESTFILES:
${BT}"
NEWEST="# Design (the newest try)

${BT}steps
- Create core/claim/claim.sh | areas: core/claim/claim.sh
${BT}

The newest try's own decision: the shape list is left alone.

${BT}acceptance
DSWORK-1[no-code]: the docs say so
TESTFILES:
${BT}"

# The model writes nothing; it only keeps the prompt it was given.
route_to_model() { printf '%s\n' "$2" > "$TEST_TEMP_DIR/prompt"; return 0; }

_fresh() {
    local d="$TEST_TEMP_DIR/run"
    rm -rf "$d"; mkdir -p "$d/state/artifacts"
    git -C "$d" init -q >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$d"
    export ZBUILD_EVENTS_JSONL="$d/state/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    _F_ART="$d/state/artifacts"; _F_DESIGN="$_F_ART/design.md"; _F_DRAFT="$_F_ART/design-draft.md"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
}
_run() {
    rm -f "$TEST_TEMP_DIR/prompt"
    _design_stage_run_inner "$TEST_TEMP_DIR/run/state/scope-manifest.md" "$_F_DESIGN" "$_F_ART" >/dev/null 2>&1
    PROMPT="$(cat "$TEST_TEMP_DIR/prompt" 2>/dev/null)"
}
# _section <heading-prefix> — the prompt's text under the first "### " heading
# starting with <heading-prefix>, up to the next "### " heading.
_section() {
    awk -v h="### $1" 'index($0, h) == 1 { on = 1; next } on && /^### / { exit } on { print }' <<< "$PROMPT"
}

print_test_section "N1, N2: after a rejected try"
_fresh; printf '%s' "$PASSED" > "$_F_DESIGN"; printf '%s' "$NEWEST" > "$_F_DRAFT"
# The previous run's try failed its checks: design's own writer records that.
_design_write_outcome "$_F_ART" unusable "design.md fails its checks" \
    "$(printf '%s\n' "The acceptance block has no WIRING line" | stage_findings_json)"
_run
_latest="$(_section "YOUR LATEST DESIGN")"
assert_contains "[N1] YOUR LATEST DESIGN is the working copy" "$_latest" "The newest try's own decision"
assert_contains "[N1] ...in full" "$_latest" "# Design (the newest try)"
if grep -qF -- "$REMOVED_STEP" <<< "$_latest"; then
    assert_fail "[N1] the step the newest try removed is not in YOUR LATEST DESIGN" "found"
else
    assert_pass "[N1] the step the newest try removed is not in YOUR LATEST DESIGN"
fi
_ref="$(_section "The last design that passed")"
assert_contains "[N2] the last passing design is shown under its own heading" "$_ref" "# Design (the one that passed)"
assert_contains "[N2] the heading says it is for reference, and not to copy back what the try removed" \
    "$(grep -F '### The last design that passed' <<< "$PROMPT")" "for reference; do not copy back what your newest try removed"

print_test_section "N3: after a try that passed"
_fresh; printf '%s' "$PASSED" > "$_F_DESIGN"
_run
_latest="$(_section "YOUR LATEST DESIGN")"
assert_contains "[N3] YOUR LATEST DESIGN is design.md" "$_latest" "# Design (the one that passed)"
if grep -qF "### The last design that passed" <<< "$PROMPT"; then
    assert_fail "[N3] no reference section" "found"
else
    assert_pass "[N3] no reference section"
fi

print_test_section "N4: the newest passing attempt, by recorded time"
# shellcheck source=../../core/plugin-registry/attempt-archive.sh
source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh"
# shellcheck source=../../scripts/lib/stage-previous-work.sh
source "$REPO_ROOT/scripts/lib/stage-previous-work.sh"
_P="$TEST_TEMP_DIR/plugins/agent/pw"; _S="$TEST_TEMP_DIR/state4"; mkdir -p "$_P" "$_S/artifacts"
cat > "$_P/manifest.yaml" <<'MF'
id: pw
kind: agent
outputs:
  - id: pw-result
    path: ${artifact_dir}/pw-result.json
    format: json
    required: true
    primary: true
  - id: pw-doc
    path: ${artifact_dir}/pw-doc.md
    format: markdown
    required: true
MF
printf '{}\n' > "$_S/pipeline-state.json"
# _archive <iter> <outcome> <doc> — one dispatch's outputs, archived by the engine's writer.
_archive() {
    stage_result_write "$_S/artifacts/pw-result.json" "$2" "try" >/dev/null 2>&1
    printf '%s\n' "$3" > "$_S/artifacts/pw-doc.md"
    ZBUILD_CYCLE_ITER="$1" ZBUILD_ARTIFACT_DIR="$_S/artifacts" \
        attempt_archive_outputs "$_P" "$_S/pipeline-state.json" pw >/dev/null 2>&1
}
_A="$_S/artifacts/attempts/pw"
# #1764's order: an earlier run passed in round 3 (11-17); this run, back in
# round 2, passed again (11-19), then a try timed out. The 11-17 attempt is
# restored from the earlier run, so its record carries that run's time and its
# files the time they were restored — the newest on disk.
_archive 3 pass "round 3, 11-17"
_archive 2 pass "round 2, 11-19"
_archive 2 timed_out "cut off"
jq '.generated_at = "2026-11-17T10:00:00Z"' "$_A/iter-3-attempt-1/attempt.json" > "$TEST_TEMP_DIR/a.json" \
    && mv "$TEST_TEMP_DIR/a.json" "$_A/iter-3-attempt-1/attempt.json"
jq '.generated_at = "2026-11-19T10:00:00Z"' "$_A/iter-2-attempt-1/attempt.json" > "$TEST_TEMP_DIR/a.json" \
    && mv "$TEST_TEMP_DIR/a.json" "$_A/iter-2-attempt-1/attempt.json"
jq '.generated_at = "2026-11-19T11:00:00Z"' "$_A/iter-2-attempt-2/attempt.json" > "$TEST_TEMP_DIR/a.json" \
    && mv "$TEST_TEMP_DIR/a.json" "$_A/iter-2-attempt-2/attempt.json"
touch "$_A/iter-3-attempt-1"/*
assert_eq "[N4] the fixture: three archived attempts" "3" \
    "$(find "$_A" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
assert_eq "[N4] the newest passing attempt is named" "$_A/iter-2-attempt-1" \
    "$(_sp_last_good_attempt "$_S" pw pw-result.json "pw-doc.md")"

# The sentence that opens design's start (the first paragraph naming the working copy or try).
_opening() { grep -E "^(The working copy|Your last try)" <<< "$PROMPT"; }
# _cut_try <draft> <rc> — a call that writes <draft> to the working copy and ends with <rc>.
_cut_try() {
    _CUT_DRAFT="$1" _CUT_RC="$2"
    route_to_model() { printf '%s' "$_CUT_DRAFT" > "$_F_DRAFT"; return "$_CUT_RC"; }
    _design_stage_run_inner "$TEST_TEMP_DIR/run/state/scope-manifest.md" "$_F_DESIGN" "$_F_ART" >/dev/null 2>&1
    route_to_model() { printf '%s\n' "$2" > "$TEST_TEMP_DIR/prompt"; cp "$_F_DRAFT" "$TEST_TEMP_DIR/draft-at-call" 2>/dev/null; return 0; }
}

print_test_section "N5: after a try cut off at its time limit"
_fresh; printf '%s' "$PASSED" > "$_F_DESIGN"
_cut_try "$NEWEST" 124
assert_eq "[N5] the fixture: the cut-off try is left as the working copy" "$NEWEST" "$(cat "$_F_DRAFT" 2>/dev/null)"
_run
_latest="$(_section "YOUR LATEST DESIGN")"
assert_contains "[N5] YOUR LATEST DESIGN is the last design that passed" "$_latest" "# Design (the one that passed)"
if grep -qF "The newest try's own decision" <<< "$_latest"; then
    assert_fail "[N5] ...not the cut-off try" "found"
else
    assert_pass "[N5] ...not the cut-off try"
fi
assert_contains "[N5] the cut-off try is shown after it, as unfinished" "$(_section "Your last try, not finished")" "The newest try's own decision"
assert_contains "[N5] the opening says the try was not finished and the last design that passed is to be refined" \
    "$(_opening)" "Your last try was not finished"
assert_eq "[N5] the working copy the call writes starts as the last design that passed" "$PASSED" \
    "$(cat "$TEST_TEMP_DIR/draft-at-call" 2>/dev/null)"

print_test_section "N6: a working copy with no acceptance block"
_fresh; printf '%s' "$PASSED" > "$_F_DESIGN"
_cut_try "# Design
Started on the claim hook." 0
_run
assert_contains "[N6] YOUR LATEST DESIGN is the last design that passed" "$(_section "YOUR LATEST DESIGN")" "# Design (the one that passed)"
assert_contains "[N6] the three-line try is shown as unfinished" "$(_section "Your last try, not finished")" "Started on the claim hook."

print_test_section "N7: the opening sentence says what is shown"
_fresh; printf '%s' "$NEWEST" > "$_F_DRAFT"
_design_write_outcome "$_F_ART" unusable "the design fails 1 of its checks" \
    "$(printf '%s\n' "The acceptance block has no WIRING line" | stage_findings_json)"
_run
if grep -qF "The last design that passed is shown after it" <<< "$PROMPT"; then
    assert_fail "[N7] with no design that passed, the opening does not say one is shown" "found"
else
    assert_pass "[N7] with no design that passed, the opening does not say one is shown"
fi
assert_contains "[N7] ...it says none has passed yet" "$(_opening)" "No design has passed yet."
assert_contains "[N7] ...and the rejected try is YOUR LATEST DESIGN" "$(_section "YOUR LATEST DESIGN")" "The newest try's own decision"
_fresh
_cut_try "$NEWEST" 124
_run
assert_contains "[N7] an unfinished try and no design that passed: the try is to be finished" "$(_opening)" "No design has passed yet."
assert_contains "[N7] ...and it is YOUR LATEST DESIGN" "$(_section "YOUR LATEST DESIGN")" "The newest try's own decision"
_fresh; printf '%s' "$PASSED" > "$_F_DESIGN"; printf '%s' "$NEWEST" > "$_F_DRAFT"
_design_write_outcome "$_F_ART" unusable "the design fails 1 of its checks" \
    "$(printf '%s\n' "The acceptance block has no WIRING line" | stage_findings_json)"
_run
assert_contains "[N7] a rejected try and a design that passed: the opening says it is shown after it" \
    "$(_opening)" "The last design that passed is shown after it for reference only."

print_test_section "N8: a working copy no result judged"
_fresh; printf '%s' "$PASSED" > "$_F_DESIGN"
_design_write_outcome "$_F_ART" pass "design_produced" "[]" "$_F_DESIGN"
printf '%s' "$NEWEST" > "$_F_DRAFT"
_run
assert_contains "[N8] YOUR LATEST DESIGN is the last design that passed" "$(_section "YOUR LATEST DESIGN")" "# Design (the one that passed)"
assert_contains "[N8] the unjudged try is shown as unfinished" "$(_section "Your last try, not finished")" "The newest try's own decision"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
