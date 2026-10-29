#!/usr/bin/env bash
# plugins/agent/review-lens/tests/review-lens-partial-notes-test.sh — a lens cut
# off by time hands over what it saved, and the review report shows it (#2270).
#
# Why: #1844 run 37066147994's correctness lens traced the whole plugin and had
# found real defects when it was killed at 300 s; the report said it "did not
# run". With save-as-you-go, its notes are on disk — the result and the report
# must carry them, marked unfinished, instead of throwing them away.
#
# N1 [change] a lens whose call times out, with notes in its notes file, puts
#             them in its result (data.partial_notes)
# N2, N3 retired with review-aggregator (#2368)
# N4 [change] a lens stopped by a signal also hands over what it saved
# N5 [change] the notes are found whatever the artifacts folder is called
# N6 [change] a lens that ran out of time says so, not "the model call failed",
#             and its summary carries what it noted so far, marked partial
#             (#1944 2026-10-28: the security lens's notes were in its result,
#             but its summary said it "reviewed nothing")
# N7 [change] one that ran out of time with nothing saved says that
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a cut-off lens hands over its notes (#2270)"
setup_test_env "review-lens-partial-notes"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

state="$TEST_TEMP_DIR/state"; artifact_dir="$state/artifacts"; mkdir -p "$artifact_dir"
export ZBUILD_STATE_DIR="$state"
scope_manifest="$TEST_TEMP_DIR/scope-manifest.md"; printf '+ core/\n' > "$scope_manifest"
evidence="$artifact_dir/diff.patch"; printf 'diff --git a/x b/x\n+ y\n' > "$evidence"

# The model call saves notes, then is cut off by the clock (rc 124).
# shellcheck disable=SC2329
route_to_model() {
    local _np; _np="$(stage_notes_path "$state" review_lenses)"; mkdir -p "${_np%/*}"
    printf 'Read plugin.sh: draft is written twice.\nNext: check the merge path.\n' > "$_np"
    return 124
}
out="$artifact_dir/lens-correctness.json"
# shellcheck disable=SC2030,SC2031  # each lens runs in its own subshell on purpose
( export ZBUILD_MAP_ELEMENT=correctness ZBUILD_REVIEW_LENS_ID=correctness
  _review_lens_run_inner "correctness" "$scope_manifest" "$evidence" "$out" "$artifact_dir" ) >/dev/null 2>&1
assert_contains "[N1] the result carries the saved notes" \
    "$(jq -r '.data.partial_notes // empty' "$out" 2>/dev/null)" "draft is written twice"

# A second lens times out with nothing saved.
# shellcheck disable=SC2329
route_to_model() { return 124; }
out2="$artifact_dir/lens-red-team.json"
# shellcheck disable=SC2030,SC2031
( export ZBUILD_MAP_ELEMENT=red-team ZBUILD_REVIEW_LENS_ID=red-team
  _review_lens_run_inner "red-team" "$scope_manifest" "$evidence" "$out2" "$artifact_dir" ) >/dev/null 2>&1

sum1="$(cat "$artifact_dir/lens-correctness-summary.md" 2>/dev/null)"
assert_contains "[N6] the summary says it ran out of time" "$sum1" "ran out of time before it finished"
assert_eq "[N6] ...not that the model call failed" "0" "$(grep -c 'the model call failed' <<< "$sum1" || true)"
assert_contains "[N6] the summary carries its notes, marked partial" "$sum1" "What it noted before it was stopped (partial)"
assert_contains "[N6] ...the notes themselves" "$sum1" "draft is written twice"
sum2="$(cat "$artifact_dir/lens-red-team-summary.md" 2>/dev/null)"
assert_contains "[N7] nothing saved: it says it ran out of time" "$sum2" "ran out of time before it finished"
assert_contains "[N7] ...and saved nothing" "$sum2" "it saved no notes"

# N2/N3 retired with review-aggregator (#2368): each lens's own result carries its notes.

# A lens stopped by a signal, with notes saved.
out4="$artifact_dir/lens-architecture.json"
_np4="$(ZBUILD_MAP_ELEMENT=architecture stage_notes_path "$state" review_lenses)"; mkdir -p "${_np4%/*}"
printf 'Read route.sh: the retry loop never resets.\n' > "$_np4"
# shellcheck disable=SC2031  # each lens runs in its own subshell on purpose
( export ZBUILD_MAP_ELEMENT=architecture
  _rl_out_ref="$out4"; _review_lens_interrupt_handler ) >/dev/null 2>&1
assert_contains "[N4] a signal-stopped lens carries its saved notes" \
    "$(jq -r '.data.partial_notes // empty' "$out4" 2>/dev/null)" "the retry loop never resets"

# An artifacts folder with another name.
odd="$TEST_TEMP_DIR/run-artifacts-x"; mkdir -p "$odd/notes"
_np5="$(ZBUILD_MAP_ELEMENT=performance stage_notes_path "/_s" review_lenses)"
printf 'Read lifecycle.sh: the lock is never released.\n' > "$odd/${_np5#/_s/artifacts/}"
assert_contains "[N5] notes found in an artifacts folder not named 'artifacts'" \
    "$(ZBUILD_MAP_ELEMENT=performance _review_lens_saved_notes "$odd" 2>/dev/null)" "the lock is never released"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
