#!/usr/bin/env bash
# Tests: cycle-orchestrator until/max_iterations/verdict-missing predicates
# (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — convergence predicate (ADR-021)"
setup_test_env "cycle-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# Predicate harness — set fields directly + call _cycle_check_until
_setup_pred() {
    _CYCLE_UNTIL_STAGE="$1"
    _CYCLE_UNTIL_FIELD="$2"
    _CYCLE_UNTIL_OP="$3"
    _CYCLE_UNTIL_VALUE="$4"
    _CYCLE_TRAP_CYCLE_ID="test"
    _CYCLE_TRAP_ITER=1
}

# T1: eq match → 0 (converged)
_setup_pred test verdict eq pass
blob='{"test":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "eq match → rc=0 (converged)" "0" "$rc"

# T2: eq mismatch → 1
blob='{"test":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "eq mismatch → rc=1" "1" "$rc"

# T3: ne match → 0
_setup_pred test verdict ne fail
blob='{"test":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "ne with non-matching value → rc=0 (converged)" "0" "$rc"

# T4: field missing → 1 (NEVER converge)
_setup_pred test verdict eq pass
blob='{"test":{"status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "field missing → rc=1 (treat as unconverged)" "1" "$rc"

# T5: stage missing → 1
blob='{"build":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "stage missing → rc=1" "1" "$rc"

# T6: empty blob → 1
set +e; _cycle_check_until '{}'; rc=$?; set -e
assert_eq "empty blob → rc=1" "1" "$rc"

# T7: max_iterations strict — iter >= max returns 0 (terminate)
set +e; _cycle_check_max_iterations 3 3; rc=$?; set -e
assert_eq "iter==max → terminate (rc=0)" "0" "$rc"
set +e; _cycle_check_max_iterations 2 3; rc=$?; set -e
assert_eq "iter<max → continue (rc=1)" "1" "$rc"
set +e; _cycle_check_max_iterations 4 3; rc=$?; set -e
assert_eq "iter>max → terminate (rc=0)" "0" "$rc"

# T8: non-numeric inputs fail-closed (rc=0=terminate, emits metric.invalid)
set +e; _cycle_check_max_iterations abc 3; rc=$?; set -e
assert_eq "non-numeric iter → terminate (fail-closed)" "0" "$rc"

# T9: status field (whitelisted alongside verdict)
_setup_pred build status eq complete
blob='{"build":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "status field eq match → converged" "0" "$rc"

print_test_results
