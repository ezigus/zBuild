#!/usr/bin/env bash
# tests/unit/own-run-artifacts-first-test.sh — a run reads its OWN work before
# an earlier run's (#2252 A).
#
# Why: hydrate restores an earlier run's artifacts so an interrupted run can
# resume. Two readers fell back to that copy whenever the live file was missing
# — including when this run had cleared its own file to redo a step:
#   - #1844 run 36969128968: design was re-entered, the cycle cleared design.md,
#     and input resolution handed design the Sept 30 run's design (without the
#     #2250 fold-in) while this run's own gate-passed design sat in its archive.
#   - #2032 run 36969130031: every build prompt said "PRIOR BUILD changed
#     nothing" — the Sept 30 run's build-summary.json — because the prior-output
#     reader checks the restored copy BEFORE this run's own.
#
# O1 [change] input resolution: live missing, this run archived it → this
#             run's newest archived copy, not the restored one
# O2 [guard]  live present → live
# O3 [guard]  this run never produced it → the restored copy (resume still works)
# O4 [change] the newest of several archived attempts wins
# O5 [change] prior-output reader: this run's live copy beats the restored one
# O6 [change] prior-output reader: live cleared, this run archived it → archived
# O7 [guard]  prior-output reader: nothing of this run's → the restored copy
# O8 [guard]  a file older than this run's start (a reused state dir's leftover)
#             is not this run's: the restored copy wins over it
# O10 [change] input resolution: a LIVE file older than this run's start (a
#             reused state dir's leftover) is not this run's either (review on
#             #2253)
# O9 [guard]  an archived copy older than this run's start is ignored too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/prior-output-reader.sh
source "$REPO_ROOT/scripts/lib/prior-output-reader.sh"

print_test_header "a run reads its own work before an earlier run's (#2252 A)"
setup_test_env "own-run-artifacts-first"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

S="$TEST_TEMP_DIR/state"; ART="$S/artifacts"; RESTORED="$S/restored-artifacts/artifacts"
mkdir -p "$ART" "$RESTORED"
export ZBUILD_STATE_DIR="$S" ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED"
printf 'OLD RUN design\n' > "$RESTORED/design.md"
# _archive <stage> <iter> <basename> <content> — what attempt-archive.sh leaves.
_archive() {
    local d="$ART/attempts/$1/iter-$2-attempt-1"
    mkdir -p "$d"; printf '%s\n' "$4" > "$d/$3"
    touch -t "20261002$(printf '%02d' "$2")00" "$d/$3"
}

print_test_section "O1-O4: input resolution"
_archive design 1 design.md "THIS RUN design round 1"
_archive design 3 design.md "THIS RUN design round 3"
_archive design 2 design.md "THIS RUN design round 2"
assert_eq "[O1/O4] live cleared → this run's newest archived design" "THIS RUN design round 3" \
    "$(cat "$(_inputs_effective_path "$ART/design.md" design)" 2>/dev/null)"
printf 'THIS RUN live design\n' > "$ART/design.md"
assert_eq "[O2] live present → live" "THIS RUN live design" \
    "$(cat "$(_inputs_effective_path "$ART/design.md" design)" 2>/dev/null)"
printf 'OLD RUN plan\n' > "$RESTORED/plan.json"
assert_eq "[O3] never produced this run → the restored copy" "OLD RUN plan" \
    "$(cat "$(_inputs_effective_path "$ART/plan.json" plan)" 2>/dev/null)"

print_test_section "O5-O7: prior-output reader"
printf 'OLD RUN build summary\n' > "$RESTORED/build-summary.json"
printf 'THIS RUN build summary\n' > "$ART/build-summary.json"
assert_eq "[O5] this run's live copy beats the restored one" "THIS RUN build summary" \
    "$(_read_prior_output build-summary.json)"
rm -f "$ART/build-summary.json"
_archive build 1 build-summary.json "THIS RUN archived build summary"
assert_eq "[O6] live cleared → this run's archived copy" "THIS RUN archived build summary" \
    "$(_read_prior_output build-summary.json)"
printf 'OLD RUN impact\n' > "$RESTORED/impact.json"
assert_eq "[O7] nothing of this run's → the restored copy" "OLD RUN impact" \
    "$(_read_prior_output impact.json)"

print_test_section "O8-O9: older than this run's start is not this run's"
S2="$TEST_TEMP_DIR/state2"; ART2="$S2/artifacts"; R2="$S2/restored-artifacts/artifacts"
mkdir -p "$ART2/attempts/plan/iter-1-attempt-1" "$R2" "$S2/runtime"
printf 'LEFTOVER plan\n' > "$ART2/plan.json"; touch -t 202609300000 "$ART2/plan.json"
printf 'LEFTOVER archived impact\n' > "$ART2/attempts/plan/iter-1-attempt-1/impact.json"
touch -t 202609300000 "$ART2/attempts/plan/iter-1-attempt-1/impact.json"
printf 'RESTORED plan\n' > "$R2/plan.json"; printf 'RESTORED impact\n' > "$R2/impact.json"
: > "$S2/runtime/run-start"
export ZBUILD_STATE_DIR="$S2" ZBUILD_RESTORED_ARTIFACTS_DIR="$R2" ZBUILD_RUN_START_MARKER="$S2/runtime/run-start"
assert_eq "[O8] a leftover older than this run's start loses to the restored copy" "RESTORED plan" \
    "$(_read_prior_output plan.json)"
rm -f "$ART2/impact.json"
assert_eq "[O9] an archived leftover is ignored too" "RESTORED impact" \
    "$(_read_prior_output impact.json)"
assert_eq "[O10] input resolution skips a live leftover too" "RESTORED plan" \
    "$(cat "$(_inputs_effective_path "$ART2/plan.json" plan)" 2>/dev/null)"
unset ZBUILD_RUN_START_MARKER

cleanup_test_env
print_test_results
exit $((FAIL > 0))
