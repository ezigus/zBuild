#!/usr/bin/env bash
# Integration: ADR-027 abort_when predicate semantics (Wave 17-B, #703).
#
# abort_when (optional) is a predicate that, when matched, terminates the
# pipeline by returning a new rc class (rc=6 cycle_abort) that propagates
# outward through every enclosing cycle to the runner. Distinct from rc=130
# (SIGINT abort) and rc=5 (blocked).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — abort_when (ADR-027 / Wave 17-B)"
setup_test_env "cycle-orch-abortwhen"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

ABORT_TPL="$TEST_TEMP_DIR/abort.yaml"
cat > "$ABORT_TPL" <<'EOF'
id: abort-test
name: abort_when test
defaults:
  strategy: fanout

flow:
  - bt_cycle

bt_cycle:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  abort_when:
    stage: test
    field: verdict
    op: eq
    value: corrupt
  max_iterations: 5
  on_max: continue

build:
  roles: [builder]

test:
  roles: [tester]
EOF

# Mock: build always passes; test returns "corrupt" on iter 1 (trigger abort).
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    case "$stage" in
        build) _CYCLE_DISPATCH_VERDICT="pass" ;;
        test)  _CYCLE_DISPATCH_VERDICT="corrupt"
               _CYCLE_DISPATCH_STATUS="failed"
               return 1
               ;;
    esac
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=()
_TPL_CYCLES=()
set +e
load_template "$ABORT_TPL"; rc=$?
set -e
assert_eq "T1: template loads rc=0" "0" "$rc"

set +e
cycle_orchestrator_run "bt_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

# T2: rc=6 (new cycle_abort class) — distinct from 0/1/2/3/4/5/130.
assert_eq "T2: orchestrator returns rc=6 cycle_abort" "6" "$rc"

# T3: terminated reason set.
assert_eq "T3: reason=cycle_abort" "cycle_abort" "$_CYCLE_LAST_TERMINATED_REASON"

# T4: _zbuild_propagate_abort recognizes rc=6 (propagates outward).
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
set +e
_zbuild_propagate_abort 6; rc2=$?
set -e
assert_eq "T4: _zbuild_propagate_abort 6 returns 6" "6" "$rc2"

# T5: rc=6 NOT generated for benign rc (smoke check).
set +e
_zbuild_propagate_abort 0; rc3=$?
set -e
assert_eq "T5: rc=0 returns 0 (non-abort)" "0" "$rc3"

# T6 (Copilot P1): grep the runner source to confirm rc=6 is in the halt
# class. This is a structural assertion — if a future change drops rc=6
# from the runner dispatch table, abort_when would silently no-op at the
# pipeline level even though the orchestrator returned cycle_abort.
RUNNER_FILE="$REPO_ROOT/core/pipeline/runner.sh"
if grep -E '_rc -eq 6' "$RUNNER_FILE" >/dev/null 2>&1; then
    assert_pass "T6: runner halt-class includes rc=6"
else
    assert_fail "T6: runner halt-class includes rc=6" \
        "runner.sh does not branch on rc=6 in cycle dispatch table"
fi

print_test_results
