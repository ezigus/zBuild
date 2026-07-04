#!/usr/bin/env bash
# [S6] Unit test (#1217, ADR-045): the `route_back:` cycle attribute parses
# from the new-shape (`flow:` + sections) template into per-cycle
# _TPL_CYCLE_ROUTE_BACK_* env vars — a sibling of exit_when/abort_when. Also
# pins that declaring route_back does NOT disturb the sibling exit_when parse.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template — route_back parse (#1217 / ADR-045)"
setup_test_env "template-route-back-parse"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

RB_TPL="$TEST_TEMP_DIR/rb.yaml"
cat > "$RB_TPL" <<'EOF'
id: rb-parse
name: rb parse
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
      op: eq
      value: retry
    max: 2
  max_iterations: 3
  on_max: continue
build:
  roles: [builder]
test:
  roles: [tester]
EOF

_TPL_STAGES=(); _TPL_CYCLES=()
set +e; load_template "$RB_TPL"; rc=$?; set -e
assert_eq "S6: template with route_back loads rc=0" "0" "$rc"

# route_back fields populated on the cycle.
assert_eq "S6: route_back.to=plan"           "plan"    "${_TPL_CYCLE_ROUTE_BACK_TO_bt_cycle:-}"
assert_eq "S6: route_back.when.stage=test"    "test"    "${_TPL_CYCLE_ROUTE_BACK_STAGE_bt_cycle:-}"
assert_eq "S6: route_back.when.field=verdict" "verdict" "${_TPL_CYCLE_ROUTE_BACK_FIELD_bt_cycle:-}"
assert_eq "S6: route_back.when.op=eq"         "eq"      "${_TPL_CYCLE_ROUTE_BACK_OP_bt_cycle:-}"
assert_eq "S6: route_back.when.value=retry"   "retry"   "${_TPL_CYCLE_ROUTE_BACK_VALUE_bt_cycle:-}"
assert_eq "S6: route_back.max=2"              "2"       "${_TPL_CYCLE_ROUTE_BACK_MAX_bt_cycle:-}"

# Regression: the sibling exit_when predicate is UNCHANGED by the route_back block.
assert_eq "S6: exit_when.stage=test still parsed" "test" "${_TPL_CYCLE_UNTIL_STAGE_bt_cycle:-}"
assert_eq "S6: exit_when.value=pass still parsed" "pass" "${_TPL_CYCLE_UNTIL_VALUE_bt_cycle:-}"

# A cycle WITHOUT route_back leaves the vars empty (primitive inert / forward-only).
NORB_TPL="$TEST_TEMP_DIR/norb.yaml"
cat > "$NORB_TPL" <<'EOF'
id: no-rb
defaults:
  strategy: fanout
flow:
  - c
c:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
build:
  roles: [builder]
test:
  roles: [tester]
EOF
_TPL_STAGES=(); _TPL_CYCLES=()
set +e; load_template "$NORB_TPL"; rc=$?; set -e
assert_eq "S6: no-route_back template loads rc=0" "0" "$rc"
assert_eq "S6: no-route_back → TO var empty (forward-only)" "" "${_TPL_CYCLE_ROUTE_BACK_TO_c:-}"

print_test_results
