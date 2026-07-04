#!/usr/bin/env bash
# [S5] Unit test (#1217, ADR-045): acyclicity carve-out for the bounded
# route_back edge.
#   (1) _tpl_validate_flow_acyclic is UNCHANGED and still rejects a genuine
#       unbounded MEMBERSHIP cycle (a cycle whose flow transitively includes
#       itself). The route_back edge lives in a SEPARATE var, so it never
#       creates a false membership cycle.
#   (2) new _tpl_validate_route_back rejects forward / self targets and a
#       non-finite / non-positive `max`; permits a bounded strictly-earlier
#       target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template — route_back acyclicity carve-out (#1217 / ADR-045)"
setup_test_env "template-route-back-validate"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

# ── (1) membership acyclicity UNCHANGED ──────────────────────────────────────
# Directly exercise _tpl_validate_flow_acyclic on a mutual-reference membership
# graph (a→b→a). This must still be rejected (ADR-027 forbids reference cycles).
_reset_flow_state() {
    _TPL_CYCLES=(); _TPL_FLOW_VISITED=()
    unset "${!_TPL_CYCLE_FLOW_@}" 2>/dev/null || true
    unset "${!_TPL_CYCLE_STAGES_@}" 2>/dev/null || true
    unset "${!_TPL_CYCLE_ROUTE_BACK_@}" 2>/dev/null || true
    unset "${!_TPL_STAGE_TYPE_@}" 2>/dev/null || true
    _TPL_DISPATCH_UNITS=()
}

_reset_flow_state
_TPL_CYCLES=(a b)
_TPL_CYCLE_FLOW_a="b"
_TPL_CYCLE_FLOW_b="a"
# The acyclic walk only descends into members typed `cycle` (ADR-027).
_TPL_STAGE_TYPE_a="cycle"
_TPL_STAGE_TYPE_b="cycle"
set +e; _tpl_validate_flow_acyclic; rc=$?; set -e
assert_eq "S5: membership cycle a<->b still REJECTED by acyclic validator" "1" "$rc"

# A route_back edge is NOT membership → acyclic validator passes (carve-out).
_reset_flow_state
_TPL_CYCLES=(bt_cycle)
_TPL_CYCLE_FLOW_bt_cycle="build,test"       # no self-reference
_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle="plan"    # backward edge, separate var
set +e; _tpl_validate_flow_acyclic; rc=$?; set -e
assert_eq "S5: route_back edge does NOT trip membership acyclicity" "0" "$rc"

# ── (2) _tpl_validate_route_back predicate ──────────────────────────────────
# Valid: to=plan is strictly EARLIER than cycle:bt_cycle, max=2 finite positive.
_reset_flow_state
_TPL_CYCLES=(bt_cycle)
_TPL_DISPATCH_UNITS=(stage:plan cycle:bt_cycle stage:pr)
_TPL_CYCLE_STAGES_bt_cycle="build,test"
_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle="plan"
_TPL_CYCLE_ROUTE_BACK_OP_bt_cycle="eq"   # supported op (persists across the cases below)
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle="2"
set +e; _tpl_validate_route_back; rc=$?; set -e
assert_eq "S5: valid backward route_back (to=plan, max=2) ACCEPTED" "0" "$rc"

# Forward: to=pr (LATER than the cycle) → rejected.
_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle="pr"
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle="2"
set +e; _tpl_validate_route_back >/dev/null 2>&1; rc=$?; set -e
assert_eq "S5: forward route_back (to=pr) REJECTED" "1" "$rc"

# Self: to=bt_cycle (the cycle itself) → rejected (not strictly earlier).
_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle="bt_cycle"
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle="2"
set +e; _tpl_validate_route_back; rc=$?; set -e
assert_eq "S5: self route_back (to=bt_cycle) REJECTED" "1" "$rc"

# Self-member: to=build (a member of bt_cycle) → resolves to the cycle's own
# index → not strictly earlier → rejected.
_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle="build"
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle="2"
set +e; _tpl_validate_route_back; rc=$?; set -e
assert_eq "S5: route_back to own member (to=build) REJECTED" "1" "$rc"

# Bad max: zero → rejected.
_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle="plan"
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle="0"
set +e; _tpl_validate_route_back; rc=$?; set -e
assert_eq "S5: route_back max=0 REJECTED" "1" "$rc"

# Bad max: non-numeric → rejected.
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle="abc"
set +e; _tpl_validate_route_back; rc=$?; set -e
assert_eq "S5: route_back max=abc REJECTED" "1" "$rc"

# Bad max: empty (unbounded) → rejected.
_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle=""
set +e; _tpl_validate_route_back; rc=$?; set -e
assert_eq "S5: route_back max empty (unbounded) REJECTED" "1" "$rc"

# ── End-to-end wiring: load_template REJECTS a forward route_back ────────────
FWD_TPL="$TEST_TEMP_DIR/fwd.yaml"
cat > "$FWD_TPL" <<'EOF'
id: fwd-rb
defaults:
  strategy: fanout
flow:
  - bt_cycle
  - deploy
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
  route_back:
    to: deploy
    when:
      stage: test
      field: verdict
      op: eq
      value: retry
    max: 2
  max_iterations: 3
build:
  roles: [builder]
test:
  roles: [tester]
deploy:
  roles: [deployer]
EOF
_reset_flow_state; _TPL_STAGES=()
set +e; load_template "$FWD_TPL" >/dev/null 2>&1; rc=$?; set -e
assert_eq "S5: load_template with forward route_back → rc=1" "1" "$rc"

# ── #1217 review fix (BLOCKING): route_back on a NESTED cycle rejected at load ─
# `inner` is a cycle-as-member of `outer` (ADR-027 recursive symmetry), so it is
# NOT a top-level dispatch unit. An inner cycle returning rc=11 has no rewind
# handler in the enclosing cycle's loop → silent HALT. Reject at load. The
# route_back here is otherwise valid (to=plan is earlier, max=2, op=eq) so ONLY
# the nested rule can trip it.
NESTED_TPL="$TEST_TEMP_DIR/nested.yaml"
cat > "$NESTED_TPL" <<'EOF'
id: nested-rb
defaults:
  strategy: fanout
flow:
  - plan
  - outer
plan:
  roles: [planner]
outer:
  type: cycle
  flow:
    - inner
  exit_when:
    stage: inner
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
inner:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  route_back:
    to: plan
    when:
      stage: test
      field: verdict
      op: eq
      value: retry
    max: 2
  max_iterations: 3
build:
  roles: [builder]
test:
  roles: [tester]
EOF
_reset_flow_state; _TPL_STAGES=()
set +e; nested_err="$(load_template "$NESTED_TPL" 2>&1)"; rc=$?; set -e
assert_eq "S5: load_template with route_back on a NESTED cycle → rc=1" "1" "$rc"
assert_contains "S5: nested-route_back error names the constraint (NESTED/top-level)" \
    "$nested_err" "top-level"

# ── #1217 review fix (NIT): unsupported route_back.when.op rejected at load ────
BADOP_TPL="$TEST_TEMP_DIR/badop.yaml"
cat > "$BADOP_TPL" <<'EOF'
id: badop-rb
defaults:
  strategy: fanout
flow:
  - plan
  - bt_cycle
plan:
  roles: [planner]
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
  route_back:
    to: plan
    when:
      stage: test
      field: verdict
      op: gt
      value: 3
    max: 2
  max_iterations: 3
build:
  roles: [builder]
test:
  roles: [tester]
EOF
_reset_flow_state; _TPL_STAGES=()
set +e; badop_err="$(load_template "$BADOP_TPL" 2>&1)"; rc=$?; set -e
assert_eq "S5: load_template with unsupported route_back op (gt) → rc=1" "1" "$rc"
assert_contains "S5: bad-op error mentions eq/ne" "$badop_err" "eq"

# Direct-call check: _tpl_validate_route_back also rejects a nested cycle when
# cycle:<cid> is absent from the dispatch units (defensive unit-level assertion).
_reset_flow_state
_TPL_CYCLES=(inner)
_TPL_DISPATCH_UNITS=(stage:plan cycle:outer)   # inner is NOT a top-level unit
_TPL_CYCLE_STAGES_outer="inner"
_TPL_CYCLE_ROUTE_BACK_TO_inner="plan"
_TPL_CYCLE_ROUTE_BACK_OP_inner="eq"
_TPL_CYCLE_ROUTE_BACK_MAX_inner="2"
set +e; _tpl_validate_route_back >/dev/null 2>&1; rc=$?; set -e
assert_eq "S5: _tpl_validate_route_back rejects nested cycle (no cycle:<cid> unit)" "1" "$rc"

print_test_results
