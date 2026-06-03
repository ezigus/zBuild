#!/usr/bin/env bash
# tests/unit/contract-validator-enforce-mode-test.sh
# Wave 12-E (#664) — default mode flip from warn → enforce.
#
# A manifest with a required input whose source: stage:X has no declared
# producer must:
#   - return rc=2 in default (no env override) mode  [enforce is default]
#   - return rc=0 when ZBUILD_CONTRACT_VALIDATOR=warn is set  [opt-out works]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "contract-validator — enforce-by-default (Wave 12-E, #664)"
setup_test_env "cv-enforce-default"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/consumer"

# A consumer that depends on stage:nonexistent — no producer in the template.
cat > "$PLUGINS_ROOT/agent/consumer/manifest.yaml" <<'EOF'
id: consumer
name: Consumer
kind: agent
version: 0.1.0
hooks:
  run: consumer_run
inputs:
  - id: phantom_artifact
    type: file
    source: stage:nonexistent
    required: true
outputs:
  - id: consumer_out
    type: file
    path: ${artifact_dir}/consumer.json
    required: true
EOF

# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# TC-1: Default mode (env unset) is now enforce → rc=2 on violation
unset ZBUILD_CONTRACT_VALIDATOR
rc=0
err_out="$(_contract_validate_pipeline "consumer" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-1: default (unset) mode is enforce — rc=2 on missing producer" "2" "$rc"
assert_contains "TC-1: structured error emitted" "$err_out" "Pipeline cannot start"

# TC-2: state stub is written in default (enforce) mode
if [[ -f "$STATE_FILE" ]]; then
    status_val="$(jq -r '.status' "$STATE_FILE" 2>/dev/null || echo "")"
    assert_eq "TC-2: state stub status=preflight_failed in default mode" \
        "preflight_failed" "$status_val"
else
    assert_fail "TC-2: state stub written in default mode" "no state file"
fi
rm -f "$STATE_FILE"

# TC-3: Explicit ZBUILD_CONTRACT_VALIDATOR=warn still works (opt-out)
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline \
    "consumer" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-3: warn opt-out returns 0 even on violation" "0" "$rc"
assert_contains "TC-3: warn mode still emits diagnostic" "$err_out" "Pipeline cannot start"
# warn mode must NOT write a preflight_failed state stub
if [[ -f "$STATE_FILE" ]]; then
    status_val="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || echo "")"
    if [[ "$status_val" == "preflight_failed" ]]; then
        assert_fail "TC-3: warn mode did NOT write preflight_failed stub" \
            "got status=preflight_failed; warn mode should not fail-closed"
    else
        assert_pass "TC-3: warn mode did NOT write preflight_failed stub"
    fi
fi

# TC-4: Explicit ZBUILD_CONTRACT_VALIDATOR=enforce still rc=2 (back-compat)
rc=0
ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "consumer" \
    "$PLUGINS_ROOT" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "TC-4: explicit enforce returns rc=2" "2" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
