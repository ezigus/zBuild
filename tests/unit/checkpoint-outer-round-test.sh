#!/usr/bin/env bash
# tests/unit/checkpoint-outer-round-test.sh — save-as-you-go notes from an
# earlier outer round are labelled as that round's, not the current state
# (#2325, ADR-063 §5/§6 with ADR-068 §2).
#
# On #2035 run 37262225813, outer round 2's test-author began with round 1's
# notes. They said "Status: DONE" and described round 1's work; nothing said
# that round's result had been rejected. It spent 3 x 15 minutes and wrote
# nothing. The notes are kept (the exploration is still useful), but the prompt
# must say plainly where they came from.
#
# O1 the outermost loop tells every stage which outer round it is in; an inner
#    loop's own round counter does not change it (ADR-068 §2: inner loops start
#    again at round 1 each outer round)
# O2 outer round 2, notes written in outer round 1: the block says they are from
#    the previous round and that its result was not accepted, and shows them
# O3 outer round 1, a retry inside the same round: the block reads as today
# O4 outer round 2, a retry inside the same round: round 2's own notes read as
#    today; round 1's stay labelled
# O5 the notes file itself is kept, never cut or deleted
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "earlier-round notes are labelled, not read as current (#2325)"
setup_test_env "checkpoint-outer-round"
unset ZBUILD_OUTER_ROUND ZBUILD_RESTORED_ARTIFACTS_DIR 2>/dev/null || true

# ─── O1: the outer round reaches every stage, nested loops included ─────────
print_test_section "O1: the outermost loop's round reaches each stage"
# shellcheck source=../lib/nested-loop-rounds-fixture.sh
source "$REPO_ROOT/tests/lib/nested-loop-rounds-fixture.sh"
ROUNDS_LOG="$TEST_TEMP_DIR/rounds.log"; : > "$ROUNDS_LOG"
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|inner=%s|outer=%s\n' "$stage" "$iter" "${ZBUILD_OUTER_ROUND:-unset}" >> "$ROUNDS_LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    case "$stage" in
        design) [[ "$iter" == "1" ]] && printf 'x' >> "$OUTER_ROUND_FILE" ;;
        design_gate)
            # Fail every design round of outer round 1, so the outer loop goes round.
            [[ "$(wc -c < "$OUTER_ROUND_FILE" | tr -d ' ')" == "1" ]] && _CYCLE_DISPATCH_VERDICT="fail" ;;
    esac
    return 0
}
_run; o1_rc=$?
assert_eq "[O1] the nested run converges in outer round 2" "0" "$o1_rc"
assert_eq "[O1] design's inner round 2 in outer round 1 is still outer round 1" \
    "1" "$(grep -c '^design|inner=2|outer=1$' "$ROUNDS_LOG" || true)"
assert_eq "[O1] design's inner round 1 in outer round 2 is outer round 2" \
    "1" "$(grep -c '^design|inner=1|outer=2$' "$ROUNDS_LOG" || true)"
assert_eq "[O1] the build loop in outer round 2 is outer round 2" \
    "1" "$(grep -c '^test|inner=1|outer=2$' "$ROUNDS_LOG" || true)"
assert_eq "[O1] no stage runs without an outer round" \
    "0" "$(grep -c 'outer=unset' "$ROUNDS_LOG" || true)"
assert_eq "[O1] the outer round is cleared when the outer loop ends" "unset" "${ZBUILD_OUTER_ROUND:-unset}"

# ─── O6: cleared on every way out of the outer loop ─────────────────────────
# A blocked build loop stops the run early (ADR-068, rc 5). The round must be
# cleared on that path too, or every stage after the loop sees a fixed round.
print_test_section "O6: the outer round is cleared when the outer loop stops early"
# shellcheck source=../lib/nested-loop-rounds-fixture.sh
# Re-source the fixture: O1 replaced its cycle_dispatch_stage with one that logs
# rounds, and O6 needs the fixture's own, which honours BUILD=blocked.
source "$REPO_ROOT/tests/lib/nested-loop-rounds-fixture.sh"
DESIGN_GATE=pass TEST=fail BUILD=blocked _run; o6_rc=$?
assert_eq "[O6] fixture: the outer loop stopped early (blocked, rc 5)" "5" "$o6_rc"
assert_eq "[O6] the outer round is cleared after an early stop" "unset" "${ZBUILD_OUTER_ROUND:-unset}"

# ─── the checkpoint block ───────────────────────────────────────────────────
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh" 2>/dev/null || true
# shellcheck source=../../scripts/lib/stage-checkpoint.sh
source "$REPO_ROOT/scripts/lib/stage-checkpoint.sh"

STATE="$TEST_TEMP_DIR/cpstate"; mkdir -p "$STATE/artifacts"
M="$TEST_TEMP_DIR/manifest.yaml"
# shellcheck disable=SC2016  # the manifest placeholder is written literally
{ printf 'id: fixture\nkind: agent\nversion: 0.1.0\n\noutputs:\n'
  printf '  - id: fixture-checkpoint\n    path: ${artifact_dir}/fixture-checkpoint.md\n'
  printf '    type: checkpoint.md\n    required: false\n    role: checkpoint\n'
} > "$M"
CP="$STATE/artifacts/fixture-checkpoint.md"
R1_NOTES='Status: DONE. Wrote tests/unit/alpha-test.sh covering R-1 and R-2.'
R2_NOTES='Round two: read the gate feedback; R-2 needs a behaviour test.'
PREV_WORDS='previous round'
NOT_ACCEPTED='not accepted'

_block() { ZBUILD_OUTER_ROUND="$1" checkpoint_prompt_block "$M" "$STATE"; }
# What the block reads like today: no outer round at all.
_today_block() { checkpoint_prompt_block "$M" "$STATE"; }

print_test_section "O3: outer round 1 and a retry inside it read as today"
_block 1 >/dev/null                      # round 1, first attempt: no notes yet
printf '%s\n' "$R1_NOTES" > "$CP"        # the model saves as it goes
o3="$(_block 1)"                         # round 1, the retry
o3_today="$(_today_block)"
assert_eq "[O3] a same-round retry in outer round 1 is byte-identical to today" "$o3_today" "$o3"
assert_contains "[O3] the notes are shown as this round's exploration" "$o3" "PRIOR EXPLORATION"
if grep -qF "$PREV_WORDS" <<<"$o3"; then
    assert_fail "[O3] outer round 1 never calls its notes the previous round's" "found: $PREV_WORDS"
else
    assert_pass "[O3] outer round 1 never calls its notes the previous round's"
fi

print_test_section "O2: outer round 2 labels round 1's notes"
o2="$(_block 2)"
assert_contains "[O2] the notes are said to be from the previous round" "$o2" "$PREV_WORDS"
assert_contains "[O2] the previous round's result is said to be not accepted" "$o2" "$NOT_ACCEPTED"
assert_contains "[O2] round 1's notes are still shown, for reference" "$o2" "$R1_NOTES"
if grep -qF "PRIOR EXPLORATION (resumed from checkpoint)" <<<"$o2"; then
    assert_fail "[O2] round 1's notes are not offered as this round's to build on" \
        "the resume heading is still present"
else
    assert_pass "[O2] round 1's notes are not offered as this round's to build on"
fi

print_test_section "O5: the notes are kept"
assert_eq "[O5] the notes file is unchanged by labelling" "$R1_NOTES" "$(cat "$CP" 2>/dev/null)"

print_test_section "O4: a retry inside outer round 2"
printf '%s\n' "$R2_NOTES" >> "$CP"       # round 2's model appends its own notes
o4="$(_block 2)"
assert_contains "[O4] round 2's own notes read as today, under the resume heading" "$o4" "PRIOR EXPLORATION (resumed from checkpoint)"
o4_current="${o4#*PRIOR EXPLORATION (resumed from checkpoint)}"
assert_contains "[O4] round 2's notes sit under the resume heading" "$o4_current" "$R2_NOTES"
if grep -qF "$R1_NOTES" <<<"$o4_current"; then
    assert_fail "[O4] round 1's notes are not presented as round 2's" "round 1 notes under the resume heading"
else
    assert_pass "[O4] round 1's notes are not presented as round 2's"
fi
o4_prev="${o4%%PRIOR EXPLORATION (resumed from checkpoint)*}"
assert_contains "[O4] round 1's notes stay labelled as the previous round's" "$o4_prev" "$PREV_WORDS"
assert_contains "[O4] round 1's notes are still there" "$o4_prev" "$R1_NOTES"

print_test_section "O2b: a stage that rewrote its notes in round 2 owns all of them"
printf 'Rewritten in round two.\n' > "$CP"
o2b="$(_block 2)"
if grep -qF "$PREV_WORDS" <<<"$o2b"; then
    assert_fail "[O2b] notes rewritten this round are not labelled as the previous round's" "found: $PREV_WORDS"
else
    assert_pass "[O2b] notes rewritten this round are not labelled as the previous round's"
fi
assert_contains "[O2b] the rewritten notes read as this round's" "$o2b" "Rewritten in round two."

cleanup_test_env
print_test_results
exit $((FAIL > 0))
