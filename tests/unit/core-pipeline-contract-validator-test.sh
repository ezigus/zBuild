#!/usr/bin/env bash
# tests/unit/core-pipeline-contract-validator-test.sh
# ADR-020 (#496) — unit tests for _contract_validate_pipeline.
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
inputs: []
outputs:
  - id: scope_manifest
    type: file
    path: \${state_dir}/scope-manifest.md
    required: true
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
inputs:
  - id: scope_manifest
    type: file
    required: true
  - id: goal_string
    type: string
    source: external
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
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
inputs:
  - id: plan
    type: file
    required: true
outputs:
  - id: diff_patch
    type: file
    path: \${artifact_dir}/diff.patch
    required: true
EOF

cat > "$PLUGINS_ROOT/tool/test/manifest.yaml" <<EOF
id: test
name: Test
kind: tool
version: 0.1.0
hooks:
  run: test_run
inputs:
  - id: diff_patch
    type: file
    required: true
outputs:
  - id: test_results
    type: file
    path: \${artifact_dir}/test-results.json
    required: true
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
inputs:
  - id: plan
    type: file
    required: true
  - id: diff_patch
    type: file
    required: true
  - id: test_results
    type: file
    required: true
outputs:
  - id: review
    type: file
    path: \${artifact_dir}/review.json
    required: true
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

# TC-3: Missing test stage — warn returns 0 but emits diagnostics
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline "intake
plan
build
review" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-3: warn mode returns 0 even on violation" "0" "$rc"
assert_contains "TC-3: warn mode emits structured error" "$err_out" "Pipeline cannot start"
assert_contains "TC-3: warn mode names missing producer" "$err_out" "test"

# TC-4: Missing test stage — enforce returns 2
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
plan
build
review" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-4: enforce mode returns rc=2 on violation" "2" "$rc"
assert_contains "TC-4: enforce mode emits 'test'" "$err_out" "test"

# TC-5: enforce-failure writes preflight_failed state stub
if [[ -f "$STATE_FILE" ]]; then
    status_val="$(jq -r '.status' "$STATE_FILE" 2>/dev/null || echo "")"
    assert_eq "TC-5: state stub status=preflight_failed" "preflight_failed" "$status_val"
else
    assert_fail "TC-5: state stub written" "no state file at $STATE_FILE"
fi
rm -f "$STATE_FILE"

# TC-6: stage ORDER no longer decides validity (#1825)
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
plan
build
review
test" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
# This ordering (review before test) was MISORDERED at the merge-base and is now
# legal. ADR-055 §1.3 legalises a producer that runs later wherever the template
# declares a re-entry reaching the consumer again — a cycle or a route_back — and
# the old forward-only rule rejected exactly those cases, which is why
# `source: artifacts` existed as an untyped escape hatch (#1768). Every name here
# resolves, so there is nothing left to refuse.
assert_eq "TC-6: a later producer is no longer refused on order alone" "0" "$rc"
# [guard] not permissiveness — an unresolvable NAME in the same shape still fails.
rc=0
# Drop `build`, the producer of the `diff_patch` that `test` requires — dropping
# `review` orphans nothing, so it would have proved the guard rather than the rule.
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
plan
test" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-6: but a name no stage produces still fails enforce" "2" "$rc"
assert_contains "TC-6: and is reported as unresolved, not misordered" "$err_out" "INPUT_UNRESOLVED"

# TC-7: External source allowlist — goal_string is OK
# (already covered by TC-1; check for negative case below)

# TC-8: Bad external source — fabricate a manifest with unknown external id
mkdir -p "$PLUGINS_ROOT/agent/bad-ext"
cat > "$PLUGINS_ROOT/agent/bad-ext/manifest.yaml" <<EOF
id: design
name: Design
kind: agent
version: 0.1.0
hooks:
  run: design_run
requires:
  core: [redaction]
inputs:
  - id: bogus_external_id
    type: string
    source: external
    required: true
outputs:
  - id: design_doc
    type: file
    path: \${artifact_dir}/design.md
    required: true
EOF
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "design" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-8: bogus external id detected" "2" "$rc"
assert_contains_regex "TC-8: bogus external diagnostic" "$err_out" "external|allowlist"
rm -f "$STATE_FILE"
rm -rf "$PLUGINS_ROOT/agent/bad-ext"

# TC-9: Bad path template variable
mkdir -p "$PLUGINS_ROOT/agent/bad-var"
cat > "$PLUGINS_ROOT/agent/bad-var/manifest.yaml" <<EOF
id: design
name: Design
kind: agent
version: 0.1.0
hooks:
  run: design_run
requires:
  core: [redaction]
inputs:
  - id: scope_manifest
    type: file
    required: true
    path: \${bogus_var}/x.md
outputs:
  - id: design_doc
    type: file
    path: \${artifact_dir}/design.md
    required: true
EOF
rc=0
err_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline "intake
design" "$PLUGINS_ROOT" "$STATE_FILE" 2>&1)" || rc=$?
assert_eq "TC-9: unknown var detected" "2" "$rc"
assert_contains_regex "TC-9: unknown var diagnostic" "$err_out" "bogus_var|unknown variable"
rm -f "$STATE_FILE"
rm -rf "$PLUGINS_ROOT/agent/bad-var"

# TC-10: enforce-default (Wave 12-E #664) — empty ZBUILD_CONTRACT_VALIDATOR
# now means `enforce`. A missing producer must therefore return rc=2.
unset ZBUILD_CONTRACT_VALIDATOR
rc=0
_contract_validate_pipeline "intake
plan
build
review" "$PLUGINS_ROOT" "$STATE_FILE" >/dev/null 2>&1 || rc=$?
assert_eq "TC-10: default (unset) ≡ enforce (rc=2 on violation)" "2" "$rc"
rm -f "$STATE_FILE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
