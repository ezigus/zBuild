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

# The gating difference itself. The lint has never gated its source switch on
# requiredness; the validator did, leaving 33 of 50 inputs unchecked. Only the
# output-id existence check may be gated, and both must gate that one — it is
# the glob fan-in carve-out (lint-contract.sh:225-231, #1279 / ADR-047 §5).
_gated_output_check() {
    grep -cE '_in_optional -eq 0 && -z "\$\{_CV_STAGE_OUTPUTS_OK|eff_required" == "true" && -z "\$\{_LC_STAGE_OUTPUTS' "$1" 2>/dev/null || echo 0
}
if [[ "$(_gated_output_check "$_LINT")" -ge 1 && "$(_gated_output_check "$_VALIDATOR")" -ge 1 ]]; then
    assert_pass "TC-4: both gate ONLY the output-id check on requiredness"
else
    assert_fail "TC-4: both gate ONLY the output-id check on requiredness" \
        "lint=$(_gated_output_check "$_LINT") validator=$(_gated_output_check "$_VALIDATOR") (want >=1 each)"
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
