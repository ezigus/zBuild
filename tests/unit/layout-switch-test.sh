#!/usr/bin/env bash
# Tests: runs actually LAND in the issue-keyed layout (#141, ADR-059 §1), and
# the reclaimers still see them.
#
# The resolver landed first (#1941) and returned the new paths while nothing
# wrote there. This is the switch: the writer now uses it. The risk this file
# exists for is the one ADR-059 names — a reader whose glob stops matching
# reports "no run is live" and un-gates three destructive scanners.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/layout.sh
source "$REPO_ROOT/core/state/layout.sh"

print_test_header "layout switch — runs land under their issue (#141)"
setup_test_env "zb-layout-switch"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
export ZBUILD_DATA_ROOT="$TEST_TEMP_DIR/data"

_repo="$TEST_TEMP_DIR/repo"; mkdir -p "$_repo"
( cd "$_repo" && git init -q -b main . && git remote add origin 'git@github.com:ezigus/zBuild.git' ) >/dev/null 2>&1

# ─── [SPEC-1][change] an issue run nests under its issue ────────────────────
print_test_section "[SPEC-1][change] issues/<N>/runs/<run_id>"

_d="$( cd "$_repo" && zbuild_layout_run_state_dir issue-1809 r-001 )"
assert_contains "[SPEC-1] the run is under the repo" "$_d" "/repos/ezigus/zBuild/"
assert_contains "[SPEC-1] and under its ISSUE" "$_d" "/issues/1809/runs/r-001"
# The per-run level survives: scratch, runtime/, events belong to ONE run.
assert_contains "[SPEC-1] the per-run level is kept" "$_d" "/runs/r-001"

_g="$( cd "$_repo" && zbuild_layout_run_state_dir goal-47bcb1fe9278 r-002 )"
assert_contains "[SPEC-1] a goal run nests under goals/" "$_g" "/goals/goal-47bcb1fe9278/runs/r-002"

# ─── [SPEC-2][guard] no identity ⇒ the flat shape, not an invented bucket ───
print_test_section "[SPEC-2][guard] a run with no identity stays flat"

_f="$( cd "$_repo" && zbuild_layout_run_state_dir "" r-003 )"
assert_eq "[SPEC-2] falls back to <state_root>/runs/<id>" \
    "$ZBUILD_STATE_ROOT/runs/r-003" "$_f"
_rc=0; zbuild_layout_run_state_dir issue-1 "" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-2] an empty run_id is refused" "1" "$_rc"

# ─── [SPEC-3][guard] THE ONE THAT MATTERS: cleanup still sees a live run ────
# ADR-059's named hazard. `_cleanup_is_active_run` gates three destructive
# scanners; if its globs stop matching the new shape it answers "no run is
# live" — the FAIL-OPEN direction — and they run against live work.
print_test_section "[SPEC-3][guard] the reclaimers still see a run in the NEW path"

# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"
unset ZBUILD_STATE_DIR 2>/dev/null || true

_live="$( cd "$_repo" && zbuild_layout_run_state_dir issue-1809 r-live )"
mkdir -p "$_live"
printf '{"run_id":"r-live","status":"in_progress"}\n' > "$_live/pipeline-state.json"

if ( cd "$_repo" && _cleanup_is_active_run r-live ); then
    assert_pass "[SPEC-3] a live run in the NEW layout is seen as active"
else
    assert_fail "[SPEC-3] cleanup went BLIND to the new layout" \
        "three destructive scanners would run against live work"
fi

# A run in the OLD flat location is still seen — operators upgrading mid-flight
# have runs there, and going blind to them is the same hazard.
_old="$ZBUILD_STATE_ROOT/runs/r-old"; mkdir -p "$_old"
printf '{"run_id":"r-old","status":"in_progress"}\n' > "$_old/pipeline-state.json"
if ( cd "$_repo" && _cleanup_is_active_run r-old ); then
    assert_pass "[SPEC-3] a live run in the OLD layout is still seen"
else
    assert_fail "[SPEC-3] cleanup went blind to pre-switch runs" "in-flight runs unprotected"
fi

# Control: a COMPLETED run is not active. Without this, a predicate that always
# said "active" would pass both assertions above and gate every reclaimer forever.
_done="$( cd "$_repo" && zbuild_layout_run_state_dir issue-1809 r-done )"
mkdir -p "$_done"
printf '{"run_id":"r-done","status":"complete"}\n' > "$_done/pipeline-state.json"
if ( cd "$_repo" && _cleanup_is_active_run r-done ); then
    assert_fail "[SPEC-3] a completed run must not read as active" "reclaimers gated forever"
else
    assert_pass "[SPEC-3] control: a completed run is not active"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
