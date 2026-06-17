#!/usr/bin/env bash
# Integration: #744/#842 — impact agent + design_impact_cycle.
#
# Drives _impact_run_inner directly with a stubbed route_to_model that
# returns a synthetic verdict. Asserts:
#   1. impact.json is written with verdict + missing[] + impact_feedback_md
#   2. impact_feedback_md sibling file is written for cycle feedback wiring
#   3. The verdict field controls cycle convergence (complete → exit, incomplete → iter)
#   4. Backward-compat: when given a plan-shaped JSON from any planner, the
#      shape is processed identically (forward compat with multi-planner futures)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "impact agent — _impact_run_inner shape + verdict-driven feedback (Wave 19-J #744)"
setup_test_env "impact-pipeline"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
: > "$ZBUILD_EVENTS_JSONL"

# #781: point ZBUILD_REPO_ROOT at an empty dir so the deterministic prefilter
# (which scans real tests/golden/** and runs CLAUDE.md grep) is a no-op for
# THIS test. These tests pre-date the prefilter and pin LLM pass-through
# behavior; entangling them with prefilter side-effects would obscure the
# original contract. Issue #781's prefilter has its own regression test at
# tests/integration/impact-prefilter-781-regression-test.sh.
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/no-prefilter-root"
mkdir -p "$ZBUILD_REPO_ROOT/config"  # config/shape-change-paths.txt absent → prefilter rc=1
# Stub the paths referenced in the synthetic LLM verdict so the hallucination
# filter (#911) does not drop them (they must exist under ZBUILD_REPO_ROOT).
mkdir -p "$ZBUILD_REPO_ROOT/tests/unit" "$ZBUILD_REPO_ROOT/tests/integration"
touch "$ZBUILD_REPO_ROOT/tests/unit/template-test.sh"
touch "$ZBUILD_REPO_ROOT/tests/integration/runner-test.sh"

ARTIFACTS="$TEST_TEMP_DIR/state/artifacts"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ARTIFACTS"

# Fixture: scope-manifest + plan.json
SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"
cat > "$SCOPE_MANIFEST" <<'EOF'
+ ./
EOF

PLAN_JSON="$ARTIFACTS/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{
  "schema_version": 1,
  "title": "test plan",
  "goal": "add feature X",
  "steps": [
    {
      "id": "step-1",
      "description": "modify standard.yaml flow",
      "files": ["config/templates/standard.yaml"],
      "estimated_lines": 20
    }
  ],
  "estimated_total_lines": 20,
  "notes": ""
}
EOF

# #842: impact reads design.md's ```scope block as the primary scope source;
# signature is <scope_manifest> <design_md> <plan_json> <impact_out> [dir].
# route_to_model is stubbed below, so the scope content only needs to be valid.
DESIGN_MD="$ARTIFACTS/design.md"
cat > "$DESIGN_MD" <<'EOF'
# Design

```scope
config/templates/standard.yaml
tests/integration/new-test.sh
```
EOF

# Stub plugin bootstrap + emit_event before sourcing plugin
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/impact"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
warn() { return 0; }
error() { echo "ERROR: $*" >&2; }

# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

# Stubs after plugin source so they override real implementations.
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { cat > "$1"; }
extract_first_json_object() { cat; }
_zbuild_sanitize_for_llm() { cat; }

print_test_section "1. impact returns verdict=incomplete with missing[] when plan has gaps"

# Stub route_to_model to return a synthetic impact verdict.
route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"step-1","files_to_add":["tests/unit/template-test.sh","tests/integration/runner-test.sh"],"reason":"standard.yaml flow shape change requires test updates"}],"impact_feedback_md":"## Impact gap on step-1\nThe standard.yaml flow change at step-1 will break assumptions in: tests/unit/template-test.sh, tests/integration/runner-test.sh. Add these to files[].\n"}'
    return 0
}

IMPACT_OUT="$ARTIFACTS/impact.json"
rm -f "$IMPACT_OUT" "$ARTIFACTS/impact_feedback.md"

set +e
_impact_run_inner "$SCOPE_MANIFEST" "$DESIGN_MD" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS"
rc=$?
set -e

assert_eq "T1: _impact_run_inner returns rc=0 on valid incomplete verdict" "0" "$rc"
assert_file_exists "T2: impact.json written" "$IMPACT_OUT"

verdict=$(jq -r '.verdict' "$IMPACT_OUT" 2>/dev/null)
assert_eq "T3: verdict=incomplete" "incomplete" "$verdict"

missing_count=$(jq -r '.missing | length' "$IMPACT_OUT" 2>/dev/null)
assert_eq "T4: missing[] has 1 entry" "1" "$missing_count"

missing_files=$(jq -r '.missing[0].files_to_add | join(",")' "$IMPACT_OUT" 2>/dev/null)
assert_eq "T5: missing[0].files_to_add preserved" "tests/unit/template-test.sh,tests/integration/runner-test.sh" "$missing_files"

# T6: impact_feedback.md sibling file written for cycle feedback wiring.
assert_file_exists "T6: impact_feedback.md sibling written" "$ARTIFACTS/impact_feedback.md"

if grep -q "Impact gap on step-1" "$ARTIFACTS/impact_feedback.md"; then
    assert_pass "T7: impact_feedback.md contains the LLM markdown"
else
    assert_fail "T7: impact_feedback.md should contain LLM markdown" "missing"
fi

print_test_section "2. impact returns verdict=complete when plan covers everything"

route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"All step files[] are complete. No gaps."}'
    return 0
}

rm -f "$IMPACT_OUT" "$ARTIFACTS/impact_feedback.md"

set +e
_impact_run_inner "$SCOPE_MANIFEST" "$DESIGN_MD" "$PLAN_JSON" "$IMPACT_OUT" "$ARTIFACTS"
rc=$?
set -e

assert_eq "T8: _impact_run_inner returns rc=0 on complete verdict" "0" "$rc"

verdict2=$(jq -r '.verdict' "$IMPACT_OUT" 2>/dev/null)
assert_eq "T9: verdict=complete" "complete" "$verdict2"

missing2_count=$(jq -r '.missing | length' "$IMPACT_OUT" 2>/dev/null)
assert_eq "T10: missing[] is empty when complete" "0" "$missing2_count"

print_test_section "3. forward-compat: unified_plan from multi-planner has same shape, processed identically"

# Synthetic unified_plan.json mimicking a future plan_merger output shape.
UNIFIED_PLAN="$ARTIFACTS/unified-plan.json"
cat > "$UNIFIED_PLAN" <<'EOF'
{
  "schema_version": 1,
  "title": "unified plan from N planners",
  "goal": "add feature X",
  "source_planners": ["test_plan", "arch_plan", "coder_plan"],
  "steps": [
    {
      "id": "step-1",
      "description": "from coder_plan: add config",
      "files": ["config/templates/standard.yaml"],
      "estimated_lines": 20
    },
    {
      "id": "step-2",
      "description": "from test_plan: add test",
      "files": ["tests/integration/new-test.sh"],
      "estimated_lines": 50
    }
  ],
  "estimated_total_lines": 70,
  "notes": ""
}
EOF

route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}'
    return 0
}

UNIFIED_IMPACT_OUT="$ARTIFACTS/impact-unified.json"
set +e
_impact_run_inner "$SCOPE_MANIFEST" "$DESIGN_MD" "$UNIFIED_PLAN" "$UNIFIED_IMPACT_OUT" "$ARTIFACTS"
rc=$?
set -e

assert_eq "T11: _impact_run_inner processes unified_plan with identical contract" "0" "$rc"

if [[ -f "$UNIFIED_IMPACT_OUT" ]]; then
    unified_verdict=$(jq -r '.verdict' "$UNIFIED_IMPACT_OUT" 2>/dev/null)
    assert_eq "T12: unified_plan impact verdict=complete (forward-compat smoke)" "complete" "$unified_verdict"
else
    assert_fail "T12: impact.json should be written for unified_plan input" "not found"
fi

print_test_results
cleanup_test_env
exit $((FAIL > 0))
