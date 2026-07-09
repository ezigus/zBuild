#!/usr/bin/env bash
# Unit: template.sh parses the cycle scope_policy block (#840 / ADR-030) and
# exports _TPL_CYCLE_SCOPE_{EXPANDABLE,AUTO_GRANT,ESCALATE,ON_DENY}_<safe_id>.
#
# scope_policy is a nested block (cf. exit_when) with a list value
# (auto_grant). Absent block ⇒ safe defaults (expandable=false). Closed enums.
# Fixtures use the recursive-flow format (exercises the second-pass parser).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: template parses cycle scope_policy (#840)"
setup_test_env "template-cycle-scope-policy-840"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

# Check parsed values regardless of overall load_template rc (parser-output
# discipline — the scope_policy must extract even if an unrelated validator
# rejects the hand-rolled fixture).
_load_quiet() { load_template "$1" >/dev/null 2>&1 || true; }

# ─── T1: full scope_policy ───────────────────────────────────────────────
T1="$TEST_TEMP_DIR/t1.yaml"
cat > "$T1" <<'YAML'
id: t1
name: t1
flow:
  - btc
btc:
  type: cycle
  flow: [build, test]
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue
  scope_policy:
    expandable: true
    auto_grant: [collateral_tests, collateral_config]
    escalate: structural
    on_deny: abandon
build:
  roles: [builder]
test:
  roles: [tester]
YAML
_load_quiet "$T1"
assert_eq "T1: expandable" "true"  "${_TPL_CYCLE_SCOPE_EXPANDABLE_btc:-}"
assert_eq "T1: auto_grant csv" "collateral_tests,collateral_config" "${_TPL_CYCLE_SCOPE_AUTO_GRANT_btc:-}"
assert_eq "T1: escalate" "structural" "${_TPL_CYCLE_SCOPE_ESCALATE_btc:-}"
assert_eq "T1: on_deny" "abandon" "${_TPL_CYCLE_SCOPE_ON_DENY_btc:-}"

# ─── T2: absent scope_policy → safe defaults ─────────────────────────────
T2="$TEST_TEMP_DIR/t2.yaml"
cat > "$T2" <<'YAML'
id: t2
name: t2
flow:
  - bare
bare:
  type: cycle
  flow: [a, b]
  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
a:
  roles: [worker]
b:
  roles: [tester]
YAML
_load_quiet "$T2"
assert_eq "T2: expandable default false" "false" "${_TPL_CYCLE_SCOPE_EXPANDABLE_bare:-false}"
assert_eq "T2: auto_grant default empty" "" "${_TPL_CYCLE_SCOPE_AUTO_GRANT_bare:-}"
assert_eq "T2: on_deny default abandon" "abandon" "${_TPL_CYCLE_SCOPE_ON_DENY_bare:-abandon}"

# ─── T3: no leak between sibling cycles ──────────────────────────────────
T3="$TEST_TEMP_DIR/t3.yaml"
cat > "$T3" <<'YAML'
id: t3
name: t3
flow:
  - withp
  - nop
withp:
  type: cycle
  flow: [a, b]
  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
  scope_policy:
    expandable: true
    auto_grant: [collateral_tests]
    escalate: none
    on_deny: abandon
nop:
  type: cycle
  flow: [c, d]
  exit_when:
    stage: d
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
a:
  roles: [worker]
b:
  roles: [tester]
c:
  roles: [worker]
d:
  roles: [tester]
YAML
_load_quiet "$T3"
assert_eq "T3: withp expandable" "true" "${_TPL_CYCLE_SCOPE_EXPANDABLE_withp:-}"
assert_eq "T3: withp escalate none" "none" "${_TPL_CYCLE_SCOPE_ESCALATE_withp:-}"
assert_eq "T3: nop expandable default false (no leak)" "false" "${_TPL_CYCLE_SCOPE_EXPANDABLE_nop:-false}"
assert_eq "T3: nop auto_grant empty (no leak)" "" "${_TPL_CYCLE_SCOPE_AUTO_GRANT_nop:-}"

# ─── T4: a `build_test_cycle`-named cycle can opt into scope expansion ────
# #979: standard.yaml (which once carried an expandable build_test_cycle) is
# retired; this pins the same contract against an owned fixture whose cycle is
# named build_test_cycle, exercising the exact safe-id export path.
T4="$TEST_TEMP_DIR/t4.yaml"
cat > "$T4" <<'YAML'
id: t4
name: t4
flow:
  - build_test_cycle
build_test_cycle:
  type: cycle
  flow: [build, test]
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  max_iterations: 5
  on_max: continue
  scope_policy:
    expandable: true
    auto_grant: [collateral_tests, collateral_config]
    escalate: structural
    on_deny: abandon
build:
  roles: [builder]
test:
  roles: [tester]
YAML
_load_quiet "$T4"
if [[ "${_TPL_CYCLE_SCOPE_EXPANDABLE_build_test_cycle:-false}" == "true" ]]; then
    assert_pass "T4: build_test_cycle scope_policy expandable=true"
else
    assert_fail "T4: build_test_cycle should be expandable" "got: ${_TPL_CYCLE_SCOPE_EXPANDABLE_build_test_cycle:-unset}"
fi

# ─── T5: invalid auto_grant class → load_template rejects ────────────────
T5="$TEST_TEMP_DIR/t5.yaml"
cat > "$T5" <<'YAML'
id: t5
name: t5
flow:
  - badc
badc:
  type: cycle
  flow: [a, b]
  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
  scope_policy:
    expandable: true
    auto_grant: [collateral_tests, not_a_real_class]
    escalate: structural
    on_deny: abandon
a:
  roles: [worker]
b:
  roles: [tester]
YAML
set +e
load_template "$T5" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    assert_pass "T5: unknown auto_grant class → load_template rc != 0"
else
    assert_fail "T5: unknown auto_grant class should be rejected" "rc=$rc"
fi

# ─── T6: invalid expandable value → load_template rejects ────────────────
T6="$TEST_TEMP_DIR/t6.yaml"
cat > "$T6" <<'YAML'
id: t6
name: t6
flow:
  - badx
badx:
  type: cycle
  flow: [a, b]
  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
  scope_policy:
    expandable: maybe
    auto_grant: [collateral_tests]
    escalate: structural
    on_deny: abandon
a:
  roles: [worker]
b:
  roles: [tester]
YAML
set +e
load_template "$T6" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    assert_pass "T6: invalid expandable → load_template rc != 0"
else
    assert_fail "T6: invalid expandable should be rejected" "rc=$rc"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
