#!/usr/bin/env bash
# Unit: template.sh parses optional cycle description: field and exports
# _TPL_CYCLE_DESCRIPTION_<safe_id> (#831).
#
# Field is operator-facing UX text only; never used in control flow.
# Absent description → var empty. Present → surrounding "..." quotes
# stripped. Mixed-cycle template tests state-leak safety.
#
# Fixtures use the recursive-flow format (matches standard.yaml's shape;
# exercises the second-pass awk parser in core/pipeline/template.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: template parses cycle description: field (#831)"
setup_test_env "template-cycle-description-831"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

# Helper: load and check description value regardless of overall validation rc.
# The description-parse contract is "the value extracted matches the YAML"; if
# load_template returns non-zero for an unrelated validation reason, the
# description value MUST still be extracted (parser-output discipline).
_load_quiet() { load_template "$1" >/dev/null 2>&1 || true; }

# ─── T1: description present in single-cycle template ────────────────────
T1_YAML="$TEST_TEMP_DIR/t1.yaml"
cat > "$T1_YAML" <<'YAML'
id: t1
name: t1
flow:
  - foo_cycle
foo_cycle:
  type: cycle
  description: Refine until verdict pass
  flow: [a, b]
  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue
a:
  roles: [worker]
b:
  roles: [tester]
YAML
_load_quiet "$T1_YAML"
assert_eq "T1: _TPL_CYCLE_DESCRIPTION_foo_cycle parsed" \
    "Refine until verdict pass" "${_TPL_CYCLE_DESCRIPTION_foo_cycle:-}"

# ─── T2: absent description → var empty ──────────────────────────────────
T2_YAML="$TEST_TEMP_DIR/t2.yaml"
cat > "$T2_YAML" <<'YAML'
id: t2
name: t2
flow:
  - bare_cycle
bare_cycle:
  type: cycle
  flow: [x, y]
  exit_when:
    stage: y
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
x:
  roles: [worker]
y:
  roles: [tester]
YAML
_load_quiet "$T2_YAML"
assert_eq "T2: _TPL_CYCLE_DESCRIPTION_bare_cycle empty when not declared" \
    "" "${_TPL_CYCLE_DESCRIPTION_bare_cycle:-}"

# ─── T3: surrounding double quotes stripped ──────────────────────────────
T3_YAML="$TEST_TEMP_DIR/t3.yaml"
cat > "$T3_YAML" <<'YAML'
id: t3
name: t3
flow:
  - quoted_cycle
quoted_cycle:
  type: cycle
  description: "Quoted description string"
  flow: [u, v]
  exit_when:
    stage: v
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
u:
  roles: [worker]
v:
  roles: [tester]
YAML
_load_quiet "$T3_YAML"
assert_eq "T3: surrounding double-quotes stripped from description" \
    "Quoted description string" "${_TPL_CYCLE_DESCRIPTION_quoted_cycle:-}"

# ─── T4: mixed template — no state leak between cycles ──────────────────
T4_YAML="$TEST_TEMP_DIR/t4.yaml"
cat > "$T4_YAML" <<'YAML'
id: t4
name: t4
flow:
  - cycle_with_desc
  - cycle_no_desc
cycle_with_desc:
  type: cycle
  description: First cycle description
  flow: [a, b]
  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
cycle_no_desc:
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
_load_quiet "$T4_YAML"
assert_eq "T4: cycle_with_desc has its description" \
    "First cycle description" "${_TPL_CYCLE_DESCRIPTION_cycle_with_desc:-}"
assert_eq "T4: cycle_no_desc has empty description (no leak from sibling)" \
    "" "${_TPL_CYCLE_DESCRIPTION_cycle_no_desc:-}"

# ─── T5: standard.yaml — all 3 cycles have descriptions ─────────────────
# Sanity check that this PR's standard.yaml updates landed.
set +e
load_template "$REPO_ROOT/config/templates/standard.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T5: standard.yaml loads rc=0" "0" "$rc"
if [[ -n "${_TPL_CYCLE_DESCRIPTION_design_impact_cycle:-}" ]]; then
    assert_pass "T5: design_impact_cycle has description ('${_TPL_CYCLE_DESCRIPTION_design_impact_cycle}')"
else
    assert_fail "T5: design_impact_cycle missing description"
fi
if [[ -n "${_TPL_CYCLE_DESCRIPTION_build_review_cycle:-}" ]]; then
    assert_pass "T5: build_review_cycle has description ('${_TPL_CYCLE_DESCRIPTION_build_review_cycle}')"
else
    assert_fail "T5: build_review_cycle missing description"
fi
if [[ -n "${_TPL_CYCLE_DESCRIPTION_build_test_cycle:-}" ]]; then
    assert_pass "T5: build_test_cycle has description ('${_TPL_CYCLE_DESCRIPTION_build_test_cycle}')"
else
    assert_fail "T5: build_test_cycle missing description"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
