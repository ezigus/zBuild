#!/usr/bin/env bash
# tests/unit/preflight-lint-parity-test.sh — ADR-020 (#496) parity meta-test.
#
# Asserts that the runtime contract validator (core/pipeline/contract-validator.sh)
# and the CI lint (scripts/lib/lint-contract.sh) see the same view of any
# given manifest set. They share scripts/lib/manifest-graph.sh as the parser
# chokepoint; if either caller starts using a different YAML reader, this
# parity check fails.
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

# TC-2: both produce the same inputs[] view on a fixture manifest.
# (#979 retired the review agent manifest; the build manifest is an equivalent
# KEEP fixture with non-empty inputs and outputs.)
FIXTURE="$REPO_ROOT/plugins/agent/build/manifest.yaml"
if [[ ! -f "$FIXTURE" ]]; then
    assert_fail "TC-2: build manifest exists" "missing $FIXTURE"
else
    inputs_from_parser="$(manifest_graph_get_inputs "$FIXTURE" | LC_ALL=C sort)"
    outputs_from_parser="$(manifest_graph_get_outputs "$FIXTURE" | LC_ALL=C sort)"
    # The shared parser is the only legitimate source; both callers use it.
    # We assert non-empty data here so a parser regression is caught even when
    # both callers regress simultaneously.
    if [[ -n "$inputs_from_parser" ]]; then
        assert_pass "TC-2: shared parser yields non-empty inputs for build.yaml"
    else
        assert_fail "TC-2: shared parser yields non-empty inputs for build.yaml" \
            "got empty result"
    fi
    if [[ -n "$outputs_from_parser" ]]; then
        assert_pass "TC-2: shared parser yields non-empty outputs for build.yaml"
    else
        assert_fail "TC-2: shared parser yields non-empty outputs for build.yaml" \
            "got empty result"
    fi
fi

# TC-3: external sources allowlist is the SAME literal in the ADR and the parser.
# #1768: retargeted from ADR-020 to ADR-055. ADR-020 is superseded, so a token
# added to the live contract would have been checked against a retired document
# — and `gh_comments` is exactly that case.
ADR="$REPO_ROOT/docs/adr/ADR-055-inter-stage-data-contract-v2.md"
parser_allow="$(manifest_graph_external_allowlist)"
for tok in $parser_allow; do
    if grep -qF "$tok" "$ADR" 2>/dev/null; then
        assert_pass "TC-3: allowlist token '$tok' is in ADR-055"
    else
        assert_fail "TC-3: allowlist token '$tok' is in ADR-055" \
            "parser declares $tok but ADR-055 doesn't mention it"
    fi
done

# ─── TC-4 (#1768): the two implementations agree on the SOURCE VOCABULARY ────
#
# This file's header promises the two callers "see the same view of any given
# manifest set", and the ADR claimed it "asserts runtime and CI lint produce
# identical results". Neither was true: TC-1 checks both files contain a
# filename string and TC-2 checks the shared parser returns non-empty. Nothing
# compared what the two implementations DECIDE.
#
# That is why they diverged undetected. `source: artifacts` was tolerated by the
# lint (lint-contract.sh:194) and would have been rejected by the validator, and
# the validator skipped its whole source switch for `required: false` inputs
# while the lint never has. Both are vocabulary disagreements this now catches.
_LINT="$REPO_ROOT/scripts/lib/lint-contract.sh"
_VALIDATOR="$REPO_ROOT/core/pipeline/contract-validator.sh"

# Which kinds each implementation names as a `case` label, derived from the
# source rather than hardcoded here — a kind added to one file and not the other
# is the defect. Labels are matched per-kind because the two files spell them
# differently: the lint combines them (`""|external|artifacts)`) while the
# validator lists one per arm (`artifacts)`).
_kinds_in() {
    local f="$1" k
    for k in external artifacts cycle_feedback 'stage:*'; do
        # A case label: start of line (any indent), the token, then `)` or `|`.
        if grep -qE "^[[:space:]]*([^)]*\|)?$(printf '%s' "$k" | sed 's/[*]/\\*/g')[)|]" "$f" 2>/dev/null; then
            printf '%s\n' "$k"
        fi
    done | LC_ALL=C sort -u
}
_lint_kinds="$(_kinds_in "$_LINT")"
_val_kinds="$(_kinds_in "$_VALIDATOR")"

if [[ -n "$_lint_kinds" && "$_lint_kinds" == "$_val_kinds" ]]; then
    assert_pass "TC-4: both implementations recognise the same source kinds"
else
    assert_fail "TC-4: both implementations recognise the same source kinds" \
        "lint: [$(echo "$_lint_kinds" | tr '\n' ' ')] validator: [$(echo "$_val_kinds" | tr '\n' ' ')]"
fi

# The gating difference itself, asserted BEHAVIOURALLY rather than by matching
# code shape — an earlier version of this grepped for a specific expression and
# broke the moment the guard was refactored, which is the failure mode a parity
# test must not have.
#
# The property: an OPTIONAL input still reaches the source-kind check (so a
# malformed source is caught), but NOT the template-aware checks (so a glob
# fan-in over a producer group is not a false positive). Both implementations
# must agree on it.
_PARITY_PL="$TEST_TEMP_DIR/parity-plugins"
mkdir -p "$_PARITY_PL/agent/pp-consumer"
cat > "$_PARITY_PL/agent/pp-consumer/manifest.yaml" <<'EOF'
id: pp-consumer
name: Parity Consumer
kind: agent
version: 0.0.1
hooks:
  run: pp_run
inputs:
  - id: bogus_optional
    source: definitely_not_a_kind
    required: false
EOF
printf 'pp_run() { :; }\n' > "$_PARITY_PL/agent/pp-consumer/plugin.sh"

# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"
set +e
_val_out="$(ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline \
    "pp-consumer" "$_PARITY_PL" "$TEST_TEMP_DIR/parity-state.json" 2>&1)"
set -e
if grep -q "BAD_SOURCE" <<< "$_val_out"; then
    assert_pass "TC-4: the validator checks the source kind of an OPTIONAL input"
else
    assert_fail "TC-4: the validator checks the source kind of an OPTIONAL input" \
        "an unrecognised source on required:false produced no violation — the pre-#1768 gate is back"
fi

# The lint half is asserted STRUCTURALLY, not behaviourally, and the reason is
# worth stating: the lint is not invocable against an isolated fixture root — it
# derives its scan set from contract participation across the real tree, so a
# standalone fixture plugin is simply not scanned and it exits silently. Driving
# it would mean reshaping the lint, which is out of scope here.
#
# So: assert it has NO requiredness gate before its source switch. That is the
# property the validator was diverging from, and it is what makes the two agree
# on the fixture above in the real tree.
if grep -qE '^[[:space:]]*if \[\[ "\$(eff_)?required" == "false" \]\]; then' "$_LINT"; then
    assert_fail "TC-4: the CI lint has no requiredness gate before its source switch" \
        "a required:false early-continue appeared in lint-contract.sh — the two implementations have swapped which one skips optional inputs"
else
    assert_pass "TC-4: the CI lint has no requiredness gate before its source switch"
fi

# And the validator must no longer skip the whole switch for optional inputs.
if grep -qE 'if \[\[ "\$in_required" == "false" \]\]; then' "$_VALIDATOR"; then
    assert_fail "TC-4: the validator does not skip its source switch for optional inputs" \
        "the blanket required:false early-continue is back in contract-validator.sh"
else
    assert_pass "TC-4: the validator does not skip its source switch for optional inputs"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
