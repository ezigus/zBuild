#!/usr/bin/env bash
# tests/unit/preflight-lint-parity-test.sh — ADR-020 (#496) parity meta-test.
#
# Asserts that the runtime contract validator (core/pipeline/contract-validator.sh)
# and the CI lint (scripts/lib/lint-contract.sh) see the same view of any
# given manifest set. They share scripts/lib/manifest-graph.sh as the parser
# chokepoint; if either caller starts using a different YAML reader, this
# parity check fails.
#
#   TC-1: both source the shared parser
#   TC-2: the shared parser yields a stage's outputs
#   TC-3: both refuse a manifest that declares inputs: (ADR-055 §1, amended
#         2026-10-12) — the same decision on the same manifest
#   TC-4: neither names an input source kind any more
#   TC-5: neither reads the retired terminal/advisory fields
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "preflight-lint parity (shared manifest-graph parser) — ADR-020 (#496)"

# TC-1: both lint and validator source the same shared parser file.
if grep -q 'manifest-graph.sh' "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>/dev/null; then
    assert_pass "TC-1: lint sources manifest-graph.sh"
else
    assert_fail "TC-1: lint sources manifest-graph.sh" "no reference in lint-contract.sh"
fi
if grep -q 'manifest-graph.sh' "$REPO_ROOT/core/pipeline/contract-validator.sh" 2>/dev/null; then
    assert_pass "TC-1: validator sources manifest-graph.sh"
else
    assert_fail "TC-1: validator sources manifest-graph.sh" "no reference in contract-validator.sh"
fi

# TC-2: the shared parser yields the outputs of a stage manifest.
FIXTURE="$REPO_ROOT/plugins/agent/build/manifest.yaml"
outputs_from_parser="$(manifest_graph_get_outputs "$FIXTURE" | LC_ALL=C sort)"
if [[ -n "$outputs_from_parser" ]]; then
    assert_pass "TC-2: shared parser yields non-empty outputs for build.yaml"
else
    assert_fail "TC-2: shared parser yields non-empty outputs for build.yaml" "got empty result"
fi

_LINT="$REPO_ROOT/scripts/lib/lint-contract.sh"
_VALIDATOR="$REPO_ROOT/core/pipeline/contract-validator.sh"

# TC-3: the same manifest, declaring inputs:, refused by both.
setup_test_env "preflight-lint-parity"
_PARITY_PL="$TEST_TEMP_DIR/parity-plugins"
mkdir -p "$_PARITY_PL/agent/pp-stage"
cat > "$_PARITY_PL/agent/pp-stage/manifest.yaml" <<'EOF'
id: pp-stage
name: Parity Stage
kind: agent
version: 0.0.1
hooks:
  run: pp_run
provides:
  result_contract: 2
inputs:
  - id: plan
outputs:
  - id: pp_result
    path: "${artifact_dir}/pp-result.json"
    type: pp-result.json@1
    format: json
    required: true
    primary: true
  - id: pp_summary
    path: "${artifact_dir}/pp-summary.md"
    type: pp-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
printf 'pp_run() { :; }\n' > "$_PARITY_PL/agent/pp-stage/plugin.sh"
# shellcheck source=../../core/pipeline/contract-validator.sh
source "$_VALIDATOR"
set +e
_val_out="$(ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline \
    "pp-stage" "$_PARITY_PL" "$TEST_TEMP_DIR/parity-state.json" 2>&1)"
_lint_out="$(ZBUILD_PLUGINS_ROOT="$_PARITY_PL" bash "$_LINT" 2>&1)"
set -e
assert_contains "TC-3: the validator refuses a declared inputs: block" "$_val_out" "INPUTS_RETIRED"
assert_contains "TC-3: the lint refuses the same block" "$_lint_out" "INPUTS_RETIRED"

# TC-4: neither names an input source kind (external, artifacts, cycle_feedback,
# stage:*) as a case label — the source vocabulary went with declared inputs.
_kinds_in() {
    local f="$1" k
    for k in external artifacts cycle_feedback 'stage:*'; do
        if grep -qE "^[[:space:]]*([^)]*\|)?$(printf '%s' "$k" | sed 's/[*]/\\*/g')[)|]" "$f" 2>/dev/null; then
            printf '%s\n' "$k"
        fi
    done
}
assert_eq "TC-4: the lint names no input source kind" "" "$(_kinds_in "$_LINT")"
assert_eq "TC-4: the validator names no input source kind" "" "$(_kinds_in "$_VALIDATOR")"

# ─── TC-5 (#1980): neither caller reads the retired terminal/advisory fields ───
# This used to assert BOTH callers went through the accessors rather than doing
# inline YAML reads, so an accessor refactor broke here instead of silently. The
# unconsumed check those accessors served is retired (#1980), so the parity
# claim inverts: neither view may read the dead vocabulary, and — the part that
# still matters — the two views must not drift apart.
for _fn in manifest_graph_output_terminal manifest_graph_output_advisory; do
    if grep -q "$_fn" "$_VALIDATOR" 2>/dev/null; then
        assert_fail "TC-5: validator no longer reads $_fn" "retired accessor still called"
    else
        assert_pass "TC-5: validator no longer reads $_fn"
    fi
    if grep -q "$_fn" "$_LINT" 2>/dev/null; then
        assert_fail "TC-5: lint no longer reads $_fn" "retired accessor still called"
    else
        assert_pass "TC-5: lint no longer reads $_fn"
    fi
done

# The surviving parity claim: OUTPUT_UNCONSUMED is gone from BOTH views, not one.
for _f in "$_VALIDATOR" "$_LINT"; do
    _n="$(basename "$_f")"
    if grep -qE 'violations\+=.*OUTPUT_UNCONSUMED|_complain.*OUTPUT_UNCONSUMED' "$_f" 2>/dev/null; then
        assert_fail "TC-5: $_n no longer raises OUTPUT_UNCONSUMED" "the check survives here"
    else
        assert_pass "TC-5: $_n no longer raises OUTPUT_UNCONSUMED"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
