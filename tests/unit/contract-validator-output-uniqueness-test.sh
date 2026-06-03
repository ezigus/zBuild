#!/usr/bin/env bash
# tests/unit/contract-validator-output-uniqueness-test.sh
# Wave 12-E (#664) — output-uniqueness check per ADR-020 amendment §D.
#
# Two stage manifests both declare `outputs: { id: diff_patch }`. The
# pre-flight validator must refuse the template with a structured error
# naming BOTH producers and the duplicate id.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "contract-validator — output-uniqueness (Wave 12-E, #664)"
setup_test_env "cv-output-uniqueness"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p \
    "$PLUGINS_ROOT/agent/intake" \
    "$PLUGINS_ROOT/agent/build" \
    "$PLUGINS_ROOT/agent/extra-build"

cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<'EOF'
id: intake
name: Intake
kind: agent
version: 0.1.0
hooks:
  run: intake_run
inputs: []
outputs:
  - id: scope_manifest
    type: file
    path: ${state_dir}/scope-manifest.md
    required: true
EOF

cat > "$PLUGINS_ROOT/agent/build/manifest.yaml" <<'EOF'
id: build
name: Build
kind: agent
version: 0.1.0
hooks:
  run: build_run
inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
outputs:
  - id: diff_patch
    type: file
    path: ${artifact_dir}/diff.patch
    required: true
EOF

# Second stage that ALSO declares diff_patch as output — this is the violation
cat > "$PLUGINS_ROOT/agent/extra-build/manifest.yaml" <<'EOF'
id: extra_build
name: Extra Build
kind: agent
version: 0.1.0
hooks:
  run: extra_build_run
inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
outputs:
  - id: diff_patch
    type: file
    path: ${artifact_dir}/diff.patch
    required: true
EOF

# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# TC-1: enforce mode rejects duplicate output id across two stages
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
build
extra_build" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-1: enforce returns rc=2 on duplicate output id" "2" "$rc"
assert_contains "TC-1: error names the duplicate id" "$err_out" "diff_patch"
assert_contains "TC-1: error names producer 'build'" "$err_out" "build"
assert_contains "TC-1: error names producer 'extra_build'" "$err_out" "extra_build"
assert_contains_regex "TC-1: error indicates duplicate/multiple producers" \
    "$err_out" "multiple|more than one|OUTPUT_DUP"

rm -f "$STATE_FILE"

# TC-2: warn mode emits diagnostic but returns 0 (opt-out preserved)
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline "intake
build
extra_build" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-2: warn mode returns 0 even on duplicate output" "0" "$rc"
assert_contains "TC-2: warn mode still surfaces the duplicate id" "$err_out" "diff_patch"

rm -f "$STATE_FILE"

# TC-3: only one stage declares the output → no violation
rc=0
ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
build" "$PLUGINS_ROOT" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "TC-3: single producer for diff_patch is fine" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
