#!/usr/bin/env bash
# Tests: pipeline final status respects on_max=continue (#796, ADR-021 v3 R1).
#
# Contract: when a cycle exhausts max_iterations with on_max=continue, the
# pipeline final status MUST NOT be terminal failure. The cycle records
# cycle.unconverged for forensics, but downstream stages get to decide.
# Only on_max=abort propagates to terminal failure.
#
# Pinned assertions (drive runner directly with synthetic state):
#   T1: stub events with cycle.unconverged on_max=continue + downstream pass
#       → final status = "complete" (or warning equivalent)
#   T2: stub events with cycle.unconverged on_max=abort
#       → final status = "failed"
#   T3: stub events with cycle.unconverged on_max=continue + downstream fail
#       → final status = "failed" (downstream's failure wins)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pipeline status respects on_max=continue (#796, ADR-021 v3 R1)"
setup_test_env "pipeline-status-on-max-continue"

# Source the runner to get _runner_final_status helper.
# shellcheck source=../../core/pipeline/runner.sh
# (We don't run the full runner — just the status-computation helper.)
# Source the template helpers + the new helper directly.
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

# Helper under test: a runner-level function that decides final pipeline status
# given (a) whether any cycle reported unconverged, (b) the on_max value of
# that cycle, (c) whether downstream stages all completed successfully.
#
# Expected signature (TDD red — function does not yet exist):
#   _runner_compute_final_status \
#       <unconverged_flag> <on_max_value> <downstream_success_flag> <status_var>

# Source runner to pick up the helper once implemented.
# shellcheck source=../../core/pipeline/runner.sh
# We avoid sourcing runner.sh here because it does heavy bootstrap; instead
# rely on the helper being available via a thin sourced extension.
# For now, define the test cases against the function signature.

# Stub helper resolution: source only the helper file when it exists.
RUNNER_FINAL_STATUS_LIB="$REPO_ROOT/scripts/lib/runner-final-status.sh"
[[ -f "$RUNNER_FINAL_STATUS_LIB" ]] && source "$RUNNER_FINAL_STATUS_LIB"

# T1: on_max=continue + downstream pass → "complete"
status=""
_runner_compute_final_status 1 "continue" 1 status
assert_eq "T1: unconverged + on_max=continue + downstream pass → complete" "complete" "$status"

# T2: on_max=abort → "failed" regardless
status=""
_runner_compute_final_status 1 "abort" 1 status
assert_eq "T2: unconverged + on_max=abort → failed" "failed" "$status"

# T3: on_max=continue + downstream fail → "failed"
status=""
_runner_compute_final_status 1 "continue" 0 status
assert_eq "T3: unconverged + on_max=continue + downstream fail → failed" "failed" "$status"

# T4: no unconverged + downstream pass → "complete" (baseline)
status=""
_runner_compute_final_status 0 "" 1 status
assert_eq "T4: no unconverged + downstream pass → complete" "complete" "$status"

# T5: no unconverged + downstream fail → "failed"
status=""
_runner_compute_final_status 0 "" 0 status
assert_eq "T5: no unconverged + downstream fail → failed" "failed" "$status"

# T6: empty on_max defaults to "abort" (conservative — historical default)
status=""
_runner_compute_final_status 1 "" 1 status
assert_eq "T6: empty on_max defaults to abort behavior → failed" "failed" "$status"

# ─── #938: the mid-run unconverged warning must match the computed status ─────
# runner.sh previously hardcoded "(pipeline_status will be 'failed')" on any
# cycle rc in {1,2,3}, contradicting an on_max=continue + downstream-approve run
# that actually computes "complete". The message is now gated on on_max.
# T7: on_max=continue → message must NOT predict 'failed'; it defers to review.
msg="$(_runner_unconverged_msg "design_impact_cycle" 1 "max_iterations" "continue")"
case "$msg" in
    *"will be 'failed'"*) assert_fail "T7: on_max=continue msg wrongly predicts failed" "$msg" ;;
    *) assert_pass "T7: on_max=continue msg does not predict failed" ;;
esac
assert_contains "T7: on_max=continue msg defers to the downstream review gate" \
    "$msg" "depends on the downstream review gate"
# T8: on_max=abort → message retains the terminal-failure prediction.
msg="$(_runner_unconverged_msg "x" 1 "max_iterations" "abort")"
assert_contains "T8: on_max=abort msg predicts failed (terminal)" \
    "$msg" "pipeline_status will be 'failed'"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
