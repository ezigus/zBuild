#!/usr/bin/env bash
# tests/unit/lint-contract-test.sh — ADR-020 (#496) lint behavior tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/lint-contract.sh — ADR-020 (#496)"
setup_test_env "lint-contract"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/intake" "$PLUGINS_ROOT/agent/plan"

# Good minimal pair
cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<EOF
id: intake
name: Intake
kind: agent
version: 0.1.0
hooks:
  run: r
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
  run: r
requires:
  core: [redaction]
inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF

# TC-1: clean fixture passes
rc=0
ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || rc=$?
assert_eq "TC-1: clean fixture passes (rc=0)" "0" "$rc"

# TC-2: source: stage:X where X doesn't exist
cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: nope
    type: file
    source: stage:nonexistent
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-2: missing stage detected (rc=1)" "1" "$rc"
assert_contains "TC-2: diagnostic names unknown stage" "$out" "nonexistent"

# TC-3: source: stage:X where X exists but doesn't declare the output id
cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: undeclared_output
    type: file
    source: stage:intake
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-3: undeclared output detected (rc=1)" "1" "$rc"
assert_contains "TC-3: diagnostic names undeclared output" "$out" "undeclared_output"

# TC-4: self-reference
cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: plan
    type: file
    source: stage:plan
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-4: self-reference detected (rc=1)" "1" "$rc"
assert_contains_regex "TC-4: diagnostic mentions self" "$out" "self-referential|self"

# TC-5: source: external for non-allowlisted id
cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: bogus_external
    type: string
    source: external
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-5: bogus external id detected (rc=1)" "1" "$rc"
assert_contains "TC-5: diagnostic mentions allowlist" "$out" "allowlist"

# TC-6: missing inputs block
cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-6: missing inputs block detected (rc=1)" "1" "$rc"
assert_contains "TC-6: diagnostic mentions inputs:" "$out" "inputs:"

# TC-7: malformed required value
cat > "$PLUGINS_ROOT/agent/plan/manifest.yaml" <<EOF
id: plan
name: Plan
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: maybe
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-7: malformed required detected (rc=1)" "1" "$rc"
assert_contains "TC-7: diagnostic mentions required:" "$out" "required:"

# TC-8: real-repo manifest set passes
rc=0
ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || rc=$?
assert_eq "TC-8: real repo plugin manifests pass lint" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
