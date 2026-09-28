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
    primary: true
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
  run: r
requires:
  core: [redaction]
inputs:
  - id: scope_manifest
    type: file
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
    primary: true
    terminal: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: plan_summary
    path: "\${artifact_dir}/plan-summary.md"
    type: plan-summary.md@1
    format: markdown
    required: true
    summary: true
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
    required: true
outputs:
  - id: plan
    type: file
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
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-2: missing stage detected (rc=1)" "1" "$rc"
# #1825: the consumer no longer names a stage, so "unknown stage" is not a thing
# the lint can say. The equivalent defect — and the one that actually bites — is
# an input naming an artifact NO plugin declares. The fixture's id is unchanged;
# only what makes it wrong has moved from the wire to the name.
assert_contains "TC-2: diagnostic names the unproduced artifact" "$out" "nope"

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
    required: true
outputs:
  - id: plan
    type: file
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
    required: true
outputs:
  - id: plan
    type: file
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
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
# #1825: SELF_REF moved to the runtime validator and became CYCLE-AWARE. A stage
# consuming its own output is legal inside a cycle — design refines its own prior
# design.md (ADR-055 §1.3) — and a defect outside one. The lint sees plugins
# without a template, so it cannot tell those apart and must not guess; the
# validator owns it (contract-validator-input-gating-test covers it there).
# The fixture below is now LEGAL to the lint, which is the assertion.
# The fixture's ONLY other property is a missing primary: on its single output,
# which is a separate rule; assert on the SELF-REFERENCE diagnostic being absent
# rather than on a clean rc, so this test pins one thing.
if grep -qiE 'self-referential|== self' <<< "$out"; then
    assert_fail "TC-4: a self-named input is not a lint-time defect" "lint still reports self-reference: $out"
else
    assert_pass "TC-4: a self-named input is not a lint-time defect"
fi

# TC-5: source: external for non-allowlisted id. #1279 (ADR-047 §5): scope is
# graph-derived, so `plan` must be a genuine data-graph node to be linted — it
# consumes stage:intake AND carries the bogus external input under test.
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
    required: true
  - id: bogus_external
    type: string
    source: external
    required: true
outputs:
  - id: plan
    type: file
    path: \${artifact_dir}/plan.json
    required: true
    primary: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: plan_summary
    path: "\${artifact_dir}/plan-summary.md"
    type: plan-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-5: bogus external id detected (rc=1)" "1" "$rc"
assert_contains "TC-5: diagnostic mentions allowlist" "$out" "allowlist"

# TC-6: missing inputs block. #1279 (ADR-047 §5): to be linted, the offending
# manifest must be a data-graph node — here `plan` is a PRODUCER (a new `consumer`
# stage reads stage:plan) that omits its inputs: block. `consumer` is otherwise
# clean, so the only violation is plan's missing inputs: block.
mkdir -p "$PLUGINS_ROOT/agent/consumer"
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
    primary: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: plan_summary
    path: "\${artifact_dir}/plan-summary.md"
    type: plan-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
cat > "$PLUGINS_ROOT/agent/consumer/manifest.yaml" <<EOF
id: consumer
name: Consumer
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: plan
    type: file
    required: true
outputs:
  - id: cout
    type: file
    path: \${artifact_dir}/cout.json
    required: true
    primary: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: consumer_summary
    path: "\${artifact_dir}/consumer-summary.md"
    type: consumer-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
rc=0
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
assert_eq "TC-6: missing inputs block detected (rc=1)" "1" "$rc"
assert_contains "TC-6: diagnostic mentions inputs:" "$out" "inputs:"
# Remove the consumer so it doesn't perturb TC-7/TC-8 topology.
rm -rf "$PLUGINS_ROOT/agent/consumer"

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
    required: maybe
outputs:
  - id: plan
    type: file
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
