#!/usr/bin/env bash
# Tests: core/state/layout.sh (#141, ADR-059 §1) — the shared definition of
# where runs live, and the fail-open hazard it exists to close.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/layout.sh
source "$REPO_ROOT/core/state/layout.sh"

print_test_header "layout resolver (#141)"
setup_test_env "zb-layout"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"

# ─── [SPEC-1][change] one definition, honouring the nested-run fence ────────
# ZBUILD_STATE_ROOT is ADR-024's #1127 fence: the test stage exports it so a
# nested runner cannot mutate its parent's state. If the resolver ignored it,
# every nested run would escape that fence.
print_test_section "[SPEC-1][change] the resolver honours ZBUILD_STATE_ROOT"

assert_eq "[SPEC-1] state root follows the fence" \
    "$TEST_TEMP_DIR/state" "$(zbuild_layout_state_root)"
assert_eq "[SPEC-1] runs root hangs off it" \
    "$TEST_TEMP_DIR/state/runs" "$(zbuild_layout_runs_root)"
assert_eq "[SPEC-1] a run dir is runs/<run_id>" \
    "$TEST_TEMP_DIR/state/runs/r-123" "$(zbuild_layout_run_dir r-123)"
_rc=0; zbuild_layout_run_dir "" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-1] an empty run_id is refused, not guessed" "1" "$_rc"

# ─── [SPEC-2][guard] the pre-#887 flat shape is still reachable ────────────
# An operator upgrading across #887 still has state files directly under the
# root. Dropping that glob would make their live runs invisible to the liveness
# check — which is the fail-open direction.
print_test_section "[SPEC-2][guard] both the per-run and the legacy flat shape are covered"

_globs="$(zbuild_layout_state_file_globs)"
assert_contains "[SPEC-2] per-run shape (#887) is covered" "$_globs" "/runs/*/pipeline-state*.json"
assert_contains "[SPEC-2] the pre-#887 flat shape is still covered" \
    "$_globs" "/state/pipeline-state*.json"

# ─── [SPEC-3][change] "I looked and found nothing" vs "I looked in the wrong
#     place" are distinguishable ────────────────────────────────────────────
# To a glob these are the same observation. To a reclaimer they are opposite
# answers, and that is exactly how a layout change becomes data loss instead of
# an error.
print_test_section "[SPEC-3][change] presence of run state is answerable"

if zbuild_layout_has_any_run_state; then
    assert_fail "[SPEC-3] an empty root must report no run state" "reported some"
else
    assert_pass "[SPEC-3] an empty root reports no run state"
fi

mkdir -p "$TEST_TEMP_DIR/state/runs/r-live"
printf '{"run_id":"r-live","status":"in_progress"}\n' \
    > "$TEST_TEMP_DIR/state/runs/r-live/pipeline-state.json"
if zbuild_layout_has_any_run_state; then
    assert_pass "[SPEC-3] a per-run state file is found"
else
    assert_fail "[SPEC-3] a per-run state file must be found" "reported none"
fi

# The legacy flat file too — asserted separately so a resolver that only ever
# matched the first glob cannot pass this section.
rm -rf "${TEST_TEMP_DIR:?}/state/runs"
printf '{"run_id":"r-flat","status":"in_progress"}\n' \
    > "$TEST_TEMP_DIR/state/pipeline-state.json"
if zbuild_layout_has_any_run_state; then
    assert_pass "[SPEC-3] a legacy flat state file is found"
else
    assert_fail "[SPEC-3] a legacy flat state file must be found" "reported none"
fi

# ─── [SPEC-4][guard] the liveness check reads the SAME place ───────────────
# The whole point: reader and writer share one definition, so they cannot
# disagree about where a run lives. This drives the real consumer.
print_test_section "[SPEC-4][guard] _cleanup_is_active_run agrees with the resolver"

# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"
unset ZBUILD_STATE_DIR 2>/dev/null || true

rm -f "$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(zbuild_layout_run_dir r-active)"
printf '{"run_id":"r-active","status":"in_progress"}\n' \
    > "$(zbuild_layout_run_dir r-active)/pipeline-state.json"
if _cleanup_is_active_run r-active; then
    assert_pass "[SPEC-4] a live run written at the resolver's path IS seen"
else
    assert_fail "[SPEC-4] the reader must see what the resolver names" "not seen"
fi

# And a finished run is not live — without this, a check that always said "live"
# would pass the assertion above and gate every reclaimer forever.
mkdir -p "$(zbuild_layout_run_dir r-done)"
printf '{"run_id":"r-done","status":"complete"}\n' \
    > "$(zbuild_layout_run_dir r-done)/pipeline-state.json"
if _cleanup_is_active_run r-done; then
    assert_fail "[SPEC-4] a completed run must not read as active" "reported active"
else
    assert_pass "[SPEC-4] a completed run is not active"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
