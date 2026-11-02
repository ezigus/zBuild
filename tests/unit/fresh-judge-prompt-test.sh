#!/usr/bin/env bash
# tests/unit/fresh-judge-prompt-test.sh — a model call that judges, and a stage
# with no tools, starts from what is true now: no notes, no "confirm it" rule
# (#2458, ADR-067 §8).
#
# Why: on #1805 (run 41489923219) issue-acceptance was handed its notes from an
# earlier run, its earlier findings and "if it is already there and right,
# confirm it and finish" — and in round 2 repeated that SPEC-1 fails while the
# test results in its own prompt showed those files passing. intake, which has
# no tools and whose reply is its output, was told the same and replied
# "confirming the existing intake" with no requirement lines: unusable, on the
# first try of every run. design's coverage check and test-author's assertion
# checks were shown their author's notes ("Status: COMPLETE — bug fixed").
#
# J1 [change] a fresh prompt holds no notes, no cut-off list, no notes-file rule
#             and no confirm rule; it says to write the whole answer from what
#             the prompt shows now, and to check an earlier finding, its own
#             included, against what is true now
# J2 [change] a building call's prompt keeps its notes, its cut-off list, its
#             notes file and the confirm rule
# J3 [change] a stage with no tools is fresh in every call
# J4 [change] every judging call composes fresh: intake (both calls), design's
#             coverage check, test-author's assertion check, issue-acceptance,
#             review-lens, security-lens, monitor; the building calls (design,
#             test-author's writing call, build) do not
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-cutoff.sh
source "$REPO_ROOT/scripts/lib/stage-cutoff.sh"
print_test_header "judging calls and no-tools stages start fresh (#2458)"
setup_test_env "fresh-judge-prompt"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# A stage that has run before: its notes, and the list of its cut-off call.
_blocks() {   # <stage> <manifest> → $BLK
    local st="$1" mf="$2" sd="$TEST_TEMP_DIR/state-$1" np cp
    mkdir -p "$sd/artifacts" "$TEST_TEMP_DIR/plugins" "$TEST_TEMP_DIR/repo"
    printf '{"stage_statuses":{"%s":"complete"}}\n' "$st" > "$sd/pipeline-state.json"
    stage_notes_path_v np "$sd" "$st"; mkdir -p "${np%/*}"
    printf 'OLD_NOTES_MARKER: SPEC-1 fails\n' > "$np"
    stage_cutoff_path_v cp "$sd" "$st"; printf -- '- Read: OLD_CUTOFF_MARKER\n' > "$cp"
    BLK=""
    stage_blocks_write_v BLK "$st" "$sd" "$mf" "$TEST_TEMP_DIR/plugins" "" "$TEST_TEMP_DIR/repo" 2>/dev/null
    export ZBUILD_STAGE_BLOCKS="$BLK"
}
NOMF="$TEST_TEMP_DIR/no-manifest.yaml"

# ── J1 / J2 ──────────────────────────────────────────────────────────────────
_blocks judge-stage "$NOMF"
_fresh="$(stage_prompt_compose_text --fresh "own text" "judged text" "limits text" 2>/dev/null)"
_lacks "[J1] a fresh prompt holds no notes" "$_fresh" "OLD_NOTES_MARKER"
_lacks "[J1] ...no list of a cut-off call" "$_fresh" "OLD_CUTOFF_MARKER"
_lacks "[J1] ...no notes file to keep" "$_fresh" "Your notes file is"
_lacks "[J1] ...no rule to confirm earlier work" "$_fresh" "confirm it and finish"
assert_contains "[J1] ...it says to write the whole answer from this prompt" "$_fresh" "Write your whole answer from what this prompt shows now"
assert_contains "[J1] ...and to check an earlier finding, its own too, against now" "$_fresh" "check it against what this prompt shows now"
assert_contains "[J1] ...and it is still the six-section contract" "$_fresh" "## Rules for this stage"
printf '%s\n' "$_fresh" > "$TEST_TEMP_DIR/fresh-prompt.txt"
if stage_prompt_check "$TEST_TEMP_DIR/fresh-prompt.txt" 2>/dev/null; then assert_pass "[J1] ...in the contract order"; else assert_fail "[J1] ...in the contract order" "stage_prompt_check refused it"; fi

_full="$(stage_prompt_compose_text "own text" "judged text" "limits text" 2>/dev/null)"
assert_contains "[J2] a building call keeps its notes" "$_full" "OLD_NOTES_MARKER"
assert_contains "[J2] ...the list of its cut-off call" "$_full" "OLD_CUTOFF_MARKER"
assert_contains "[J2] ...its notes file" "$_full" "Your notes file is"
assert_contains "[J2] ...and the confirm rule" "$_full" "confirm it and finish"
_partsf="$(stage_prompt_compose_parts --fresh "$(printf '## What you own\nx\n## What you judge against\ny\n## What you must not do\nz')" 2>/dev/null)"
_lacks "[J1] composing from parts, fresh holds no notes either" "$_partsf" "OLD_NOTES_MARKER"
assert_contains "[J1] ...and says to write the whole answer" "$_partsf" "Write your whole answer"

# ── J3 ───────────────────────────────────────────────────────────────────────
_blocks intake "$REPO_ROOT/plugins/agent/intake/manifest.yaml"
_nt="$(stage_prompt_compose_text "own text" "judged text" "limits text" 2>/dev/null)"
_lacks "[J3] a stage with no tools gets no notes" "$_nt" "OLD_NOTES_MARKER"
_lacks "[J3] ...and is not told to confirm earlier work" "$_nt" "confirm it and finish"
assert_contains "[J3] ...it is told to write its whole answer" "$_nt" "Write your whole answer"

# ── J4 ───────────────────────────────────────────────────────────────────────
# Each judging call site composes fresh; each building call site does not.
_site_fresh() {   # <label> <file> <want: fresh|full>
    local f="$REPO_ROOT/$2" n_all n_fresh
    n_all="$(grep -cE 'stage_prompt_compose_(text|parts) ' "$f" || true)"
    n_fresh="$(grep -cE 'stage_prompt_compose_(text|parts) --fresh ' "$f" || true)"
    if [[ "$3" == fresh ]]; then
        assert_eq "[J4] $1 composes every prompt fresh" "$n_all" "$n_fresh"
        assert_gt "[J4] ...and composes one at all" "$n_all" "0"
    else
        assert_eq "[J4] $1 keeps its notes" "0" "$n_fresh"
    fi
}
_site_fresh "intake (its requirements and their check)" plugins/agent/intake/lib/requirements.sh fresh
_site_fresh "design's coverage check" plugins/agent/design/lib/coverage.sh fresh
_site_fresh "test-author's assertion check" plugins/agent/test-author/lib/correspondence.sh fresh
_site_fresh "issue-acceptance" plugins/agent/issue-acceptance/plugin.sh fresh
_site_fresh "review-lens" plugins/agent/review-lens/plugin.sh fresh
_site_fresh "security-lens" plugins/agent/security-lens/plugin.sh fresh
_site_fresh "monitor" plugins/agent/monitor/plugin.sh fresh
_site_fresh "design's writing call" plugins/agent/design/plugin.sh full
_site_fresh "test-author's writing call" plugins/agent/test-author/plugin.sh full
_site_fresh "build" plugins/agent/build/plugin.sh full

cleanup_test_env
print_test_results
exit $((FAIL > 0))
