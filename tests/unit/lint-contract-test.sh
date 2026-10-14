#!/usr/bin/env bash
# tests/unit/lint-contract-test.sh — scripts/lib/lint-contract.sh behaviour.
#
# The lint checks what a STAGE declares it writes (ADR-020 §D, ADR-055 §9) and
# that it declares no inputs (ADR-055 §1, amended 2026-10-12). A stage is a
# manifest that writes a stage result (provides.result_contract).
#
#   TC-1: a clean pair of stages passes
#   TC-2: a stage declaring inputs: is refused (INPUTS_RETIRED)
#   TC-3: a stage with no primary output is refused
#   TC-4: a stage with no summary output is refused (SUMMARY_MISSING)
#   TC-5: a manifest that writes no stage result is not linted
#   TC-6: the real repository's manifests pass
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/lint-contract.sh — what a stage declares it writes"
setup_test_env "lint-contract"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/intake" "$PLUGINS_ROOT/agent/plan"

_lint() { ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1; }

# _plan_manifest [extra-top-level-yaml] [primary:true|false] [summary:true|false]
_plan_manifest() {
    local extra="${1:-}" primary="${2:-true}" summary="${3:-true}"
    {
        cat <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
provides:
  result_contract: 3
  role: planner
EOF
        [[ -n "$extra" ]] && printf '%s\n' "$extra"
        cat <<EOF
outputs:
  - id: plan
    type: plan.json@1
    format: json
    path: \${artifact_dir}/plan.json
    required: true
EOF
        [[ "$primary" == "true" ]] && printf '    primary: true\n'
        if [[ "$summary" == "true" ]]; then
            cat <<EOF
  - id: plan_summary
    path: "\${artifact_dir}/plan-summary.md"
    type: plan-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
        fi
    } > "$PLUGINS_ROOT/agent/plan/manifest.yaml"
}

cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<EOF
id: intake
name: Intake
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
provides:
  result_contract: 3
  role: intake
outputs:
  - id: scope_manifest
    type: scope-manifest.md@1
    format: markdown
    path: \${state_dir}/scope-manifest.md
    required: true
    primary: true
  - id: intake_summary
    path: "\${artifact_dir}/intake-summary.md"
    type: intake-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

# TC-1
_plan_manifest
rc=0; out="$(_lint)" || rc=$?
assert_eq "TC-1: clean fixture passes (rc=0)" "0" "$rc"

# TC-2
_plan_manifest $'inputs:\n  - id: scope_manifest'
rc=0; out="$(_lint)" || rc=$?
assert_eq "TC-2: a stage declaring inputs: is refused (rc=1)" "1" "$rc"
assert_contains "TC-2: diagnostic says inputs are retired" "$out" "INPUTS_RETIRED"

# TC-3
_plan_manifest "" false true
rc=0; out="$(_lint)" || rc=$?
assert_eq "TC-3: a stage with no primary output is refused (rc=1)" "1" "$rc"
assert_contains "TC-3: diagnostic names primary" "$out" "primary: true"

# TC-4
_plan_manifest "" true false
rc=0; out="$(_lint)" || rc=$?
assert_eq "TC-4: a stage with no summary output is refused (rc=1)" "1" "$rc"
assert_contains "TC-4: diagnostic names SUMMARY_MISSING" "$out" "SUMMARY_MISSING"

# TC-5
_plan_manifest
mkdir -p "$PLUGINS_ROOT/tool/backend"
cat > "$PLUGINS_ROOT/tool/backend/manifest.yaml" <<EOF
id: backend
name: Backend
kind: tool
version: 0.1.0
hooks:
  run: r
outputs:
  - id: backend_out
    path: \${state_dir}/backend.md
EOF
rc=0; out="$(_lint)" || rc=$?
assert_eq "TC-5: a manifest writing no stage result is not linted (rc=0)" "0" "$rc"
rm -rf "$PLUGINS_ROOT/tool/backend"

# TC-6
rc=0
ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || rc=$?
assert_eq "TC-6: real repo plugin manifests pass lint" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
