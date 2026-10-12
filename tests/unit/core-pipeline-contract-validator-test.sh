#!/usr/bin/env bash
# tests/unit/core-pipeline-contract-validator-test.sh
# ADR-020 (#496) — unit tests for _contract_validate_pipeline.
#
#   TC-1/2: a clean stage list passes, warn and enforce
#   TC-3:   warn mode reports a violation and returns 0
#   TC-4:   enforce mode returns 1 on the same violation
#   TC-5:   an enforce failure writes the preflight_failed state stub, with
#           reason contract_violation
#   TC-6:   stage order decides nothing — no stage declares inputs
#   TC-10:  an unset mode means enforce
# The violation used throughout is a manifest still declaring inputs: — retired
# (ADR-055 §1, amended 2026-10-12), refused as INPUTS_RETIRED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/contract-validator — ADR-020 (#496)"
setup_test_env "contract-validator"

# Build a tiny plugin tree with minimal manifests
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/intake" "$PLUGINS_ROOT/agent/plan" "$PLUGINS_ROOT/agent/build" "$PLUGINS_ROOT/tool/test" "$PLUGINS_ROOT/agent/review"

cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<EOF
id: intake
name: Intake
kind: agent
version: 0.1.0
hooks:
  run: intake_run
requires:
  core: [redaction]
outputs:
  - id: scope_manifest
    type: file@1
    format: text
    path: \${state_dir}/scope-manifest.md
    required: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: intake_summary
    path: "\${artifact_dir}/intake-summary.md"
    type: intake-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: plan_run
requires:
  core: [redaction]
outputs:
  - id: plan
    type: file@1
    format: text
    path: \${artifact_dir}/plan.json
    required: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: plan_summary
    path: "\${artifact_dir}/plan-summary.md"
    type: plan-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

cat > "$PLUGINS_ROOT/agent/build/manifest.yaml" <<EOF
id: build
name: Build
kind: agent
version: 0.1.0
hooks:
  run: build_run
requires:
  core: [redaction]
outputs:
  - id: diff_patch
    type: file@1
    format: text
    path: \${artifact_dir}/diff.patch
    required: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: build_summary
    path: "\${artifact_dir}/build-summary.md"
    type: build-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

cat > "$PLUGINS_ROOT/tool/test/manifest.yaml" <<EOF
id: test
name: Test
kind: tool
version: 0.1.0
hooks:
  run: test_run
outputs:
  - id: test_results
    type: file@1
    format: text
    path: \${artifact_dir}/test-results.json
    required: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: test_summary
    path: "\${artifact_dir}/test-summary.md"
    type: test-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

cat > "$PLUGINS_ROOT/agent/review/manifest.yaml" <<EOF
id: review
name: Review
kind: agent
version: 0.1.0
hooks:
  run: review_run
requires:
  core: [redaction]
outputs:
  - id: review
    type: file@1
    format: text
    path: \${artifact_dir}/review.json
    required: true
    terminal: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: review_summary
    path: "\${artifact_dir}/review-summary.md"
    type: review-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

# Source the validator
# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# TC-1: Happy path — full standard stage list passes (warn mode)
rc=0
ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline "intake
plan
build
test
review" "$PLUGINS_ROOT" "$STATE_FILE" 2>/dev/null || rc=$?
assert_eq "TC-1: happy path passes in warn mode" "0" "$rc"

# TC-2: Happy path — enforce mode also passes
rc=0
ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
plan
build
test
review" "$PLUGINS_ROOT" "$STATE_FILE" 2>/dev/null || rc=$?
assert_eq "TC-2: happy path passes in enforce mode" "0" "$rc"

# A stage written for the old contract: it still declares inputs.
mkdir -p "$PLUGINS_ROOT/agent/legacy"
cat > "$PLUGINS_ROOT/agent/legacy/manifest.yaml" <<EOF
id: legacy
name: Legacy
kind: agent
version: 0.1.0
hooks:
  run: legacy_run
requires:
  core: [redaction]
inputs:
  - id: plan
    required: true
outputs:
  - id: legacy_out
    type: file@1
    format: text
    path: \${artifact_dir}/legacy.json
    required: true
  - id: legacy_summary
    path: "\${artifact_dir}/legacy-summary.md"
    type: legacy-summary.md@1
    format: markdown
    required: true
    summary: true
EOF

# TC-3: warn returns 0 but emits diagnostics
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline "intake
plan
legacy" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-3: warn mode returns 0 even on violation" "0" "$rc"
assert_contains "TC-3: warn mode emits structured error" "$err_out" "Pipeline cannot start"
assert_contains "TC-3: warn mode names the retired inputs" "$err_out" "INPUTS_RETIRED"

# TC-4: enforce returns 1
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
plan
legacy" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-4: enforce mode returns rc=1 on violation (#1850: was 2)" "1" "$rc"
assert_contains "TC-4: enforce mode names the stage" "$err_out" "legacy"

# TC-5: enforce-failure writes preflight_failed state stub
if [[ -f "$STATE_FILE" ]]; then
    assert_eq "TC-5: state stub status=preflight_failed" "preflight_failed" "$(jq -r '.status' "$STATE_FILE" 2>/dev/null)"
    assert_eq "TC-5: state stub reason=contract_violation" "contract_violation" "$(jq -r '.reason' "$STATE_FILE" 2>/dev/null)"
else
    assert_fail "TC-5: state stub written" "no state file at $STATE_FILE"
fi
rm -f "$STATE_FILE"

# TC-6: order decides nothing — the clean set passes in any order.
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "review
test
build
plan
intake" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-6: reversed stage order passes" "0" "$rc"
rm -f "$STATE_FILE"

# TC-10: enforce-default (Wave 12-E #664) — empty ZBUILD_CONTRACT_VALIDATOR
# means `enforce`.
unset ZBUILD_CONTRACT_VALIDATOR
rc=0
_contract_validate_pipeline "intake
legacy" "$PLUGINS_ROOT" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "TC-10: default (unset) ≡ enforce (rc=1 on violation)" "1" "$rc"
rm -f "$STATE_FILE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
