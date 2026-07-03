#!/usr/bin/env bash
# Integration: Wave 19-C-1 (#725) — cycle.predicate.evaluated instrumentation.
#
# Drives a minimal cycle and asserts that every predicate evaluation
# (`until/exit_when` and `abort_when`) emits one
# `cycle.predicate.evaluated` event with the expected payload shape.
#
# Without this, future predicate-mismatch bugs repeat the same forensic
# dance we ran for Waves 19-A (#717) and 19-C (#725/#726).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle.predicate.evaluated instrumentation (Wave 19-C-1 #725)"
setup_test_env "cycle-predicate-event"

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

# ── Section 1: exit_when (until) matches first iter ─────────────────────────
print_test_section "1. exit_when match → cycle.predicate.evaluated kind=exit_when match=true"

TPL1="$TEST_TEMP_DIR/exit-when.yaml"
cat > "$TPL1" <<'EOF'
id: pred_exit_when
name: Predicate Event Test (exit_when)
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  max_iterations: 2
  on_max: continue

review:
  roles: [reviewer]
EOF

cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT="approve"
    _CYCLE_DISPATCH_VERDICT_RAW="approve"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL1" || assert_fail "template load"

set +e; cycle_orchestrator_run "the_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "cycle converges rc=0" "0" "$rc"

ev_count=$(jq -c 'select(.type=="cycle.predicate.evaluated" and .data.cycle_id=="the_cycle" and .data.kind=="exit_when")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one cycle.predicate.evaluated kind=exit_when emitted" "1" "$ev_count"

ev_match=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.match' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when match=true (predicate satisfied)" "true" "$ev_match"

ev_stage=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.stage' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload stage=review" "review" "$ev_stage"

ev_actual=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.actual' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload actual=approve" "approve" "$ev_actual"

ev_expected=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.expected' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload expected=approve" "approve" "$ev_expected"

# Copilot review (#727): pin the full payload contract so a regression that
# emits the event with a missing field would surface immediately.
ev_field=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.field' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload field=verdict" "verdict" "$ev_field"

ev_op=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.op' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload op=eq" "eq" "$ev_op"

ev_iter=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.iter' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload iter=1 (matched on first iter)" "1" "$ev_iter"

ev_cycle_id=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.cycle_id' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload cycle_id=the_cycle" "the_cycle" "$ev_cycle_id"

# ── Section 2: abort_when matches first iter ────────────────────────────────
print_test_section "2. abort_when match → cycle.predicate.evaluated kind=abort_when match=true"

: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

TPL2="$TEST_TEMP_DIR/abort-when.yaml"
cat > "$TPL2" <<'EOF'
id: pred_abort_when
name: Predicate Event Test (abort_when)
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  abort_when:
    stage: review
    field: verdict
    op: eq
    value: block
  max_iterations: 3
  on_max: continue

review:
  roles: [reviewer]
EOF

cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT="block"
    _CYCLE_DISPATCH_VERDICT_RAW="block"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL2" || assert_fail "template load"

set +e; cycle_orchestrator_run "the_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "cycle aborts rc=6 (cycle_abort)" "6" "$rc"

aw_count=$(jq -c 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one cycle.predicate.evaluated kind=abort_when emitted" "1" "$aw_count"

aw_match=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.match' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "abort_when match=true (block matched)" "true" "$aw_match"

aw_actual=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.actual' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "abort_when payload actual=block" "block" "$aw_actual"

aw_field=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.field' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "abort_when payload field=verdict" "verdict" "$aw_field"

aw_op=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.op' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "abort_when payload op=eq" "eq" "$aw_op"

aw_expected=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.expected' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "abort_when payload expected=block" "block" "$aw_expected"

aw_iter=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.iter' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "abort_when payload iter=1" "1" "$aw_iter"

# Also verify exit_when fired AND matched=false (sanity: predicate ordering — exit_when before abort_when)
ew2_match=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.match' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when match=false when verdict!=approve" "false" "$ew2_match"

# ── Section 3: until non-match → match=false ────────────────────────────────
print_test_section "3. exit_when non-match → cycle.predicate.evaluated match=false"

: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_VERDICT_RAW="request_changes"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL1" || assert_fail "template load"

# max_iterations=2, dispatch returns "request_changes" (rc=0, no failing test)
# every time, no abort_when → cycle runs both iters and terminates at exhaustion.
# #1208 by-severity: no test verdict==fail and failure_count==0 → rc=2
# (unconverged→review), not the old max_iterations rc=1.
set +e; cycle_orchestrator_run "the_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "cycle reaches exhaustion, tests not failing → rc=2 (unconverged→review, #1208)" "2" "$rc"

# Two iters → two exit_when evaluations, both match=false
nomatch_count=$(jq -c 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when" and .data.match=="false")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exit_when match=false fires once per non-matching iter (2 iters)" "2" "$nomatch_count"

nomatch_actual=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.actual' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "exit_when payload actual=request_changes (raw verdict, not classified)" "request_changes" "$nomatch_actual"

print_test_results
exit $((FAIL > 0))
