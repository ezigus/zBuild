#!/usr/bin/env bash
# Tests: #1768 — the runtime validator gates its source switch like the CI lint.
# Covers SPEC-1 through SPEC-6.
#
# Before this change `contract-validator.sh:317` skipped the ENTIRE source switch
# for any `required: false` input — 33 of 50 inputs in the tree, two thirds. The
# CI lint (scripts/lib/lint-contract.sh) has never gated it. That one difference
# is the defect: a malformed source, an unrecognised kind, and two of the four
# cycle_feedback rules were all invisible at runtime on an optional input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

print_test_header "contract-validator input gating — #1768"

setup_test_env "contract-validator-input-gating"

_PL="$TEST_TEMP_DIR/plugins"

# _mk <id> <inputs-yaml-or-empty> <outputs-yaml-or-empty>
_mk() {
    local id="$1" ins="$2" outs="$3"
    mkdir -p "$_PL/agent/$id"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\nhooks:\n  run: %s_run\n' "$id" "$id" "${id//-/_}"
        [[ -n "$ins" ]]  && printf 'inputs:\n%s\n' "$ins"
        [[ -n "$outs" ]] && printf 'outputs:\n%s\n' "$outs"
    } > "$_PL/agent/$id/manifest.yaml"
    printf '%s_run() { :; }\n' "${id//-/_}" > "$_PL/agent/$id/plugin.sh"
}

# _raw <stage-list...> — the validator's full rendered output. The violation
# detail renders on the line AFTER the code line, so a code-only grep drops it.
_raw() {
    local stages; stages="$(printf '%s\n' "$@")"
    ZBUILD_CONTRACT_VALIDATOR=warn _contract_validate_pipeline \
        "$stages" "$_PL" "$TEST_TEMP_DIR/state.json" 2>&1 || true
}

# _validate <stage-list...> — the violation code lines only.
_validate() {
    _raw "$@" | grep -E "BAD_SOURCE|SELF_REF|MISSING_OUTPUT|BAD_EXTERNAL|INPUT_UNRESOLVED|INPUT_AMBIGUOUS|CYCLE_FB" || true
}

_producer_outs='  - id: prod_out
    path: "${artifact_dir}/prod-out.md"
    type: text/markdown'

# ─── SPEC-1: an OPTIONAL input with an unrecognised source is caught ─────────
# CHANGE: at the merge-base this was silent — the required-only gate meant the
# switch never ran, so the wildcard BAD_SOURCE arm was unreachable for it.
_mk producer "" "$_producer_outs"
_mk c1 '  - id: bogus
    source: not_a_real_kind
    required: false' ""
_out="$(_validate producer c1)"
_out_full="$(_raw producer c1)"
if grep -q "BAD_SOURCE" <<< "$_out"; then
    assert_pass "[SPEC-1] an optional input's unrecognised source is caught"
else
    assert_fail "[SPEC-1] an optional input's unrecognised source is caught" "got: ${_out:-<no violations>}"
fi

# ─── SPEC-2: the message enumerates every valid kind ────────────────────────
# It used to read "must be 'stage:<name>' or 'external'", omitting two kinds the
# switch accepts a few lines above — an author was told their valid value was
# not an option.
# `|| true`: under `set -o pipefail` a non-matching grep fails the whole
# assignment and kills the run, which would hide every assertion after this one
# in exactly the ablation case these SPECs exist to demonstrate.
_msg="$( { grep -A 1 "BAD_SOURCE" <<< "$_out_full" || true; } | tail -1)"
for _kind in external; do
    if grep -qF "$_kind" <<< "$_msg"; then
        assert_pass "[SPEC-2] BAD_SOURCE message lists '$_kind'"
    else
        assert_fail "[SPEC-2] BAD_SOURCE message lists '$_kind'" "message: ${_msg:-<empty>}"
    fi
done

# ─── SPEC-3 removed by #1825 ───────────────────────────────────────────────
# It asserted `source: artifacts` is ACCEPTED at both requirednesses. ADR-055 §1
# retires that kind, so acceptance is now the defect — the arm it tested is gone
# and an unrecognised source is BAD_SOURCE (SPEC-2 covers that).

# ─── SPEC-4 / SPEC-4b removed by #1825 ─────────────────────────────────────
# They asserted CYCLE_FB_DIR and CYCLE_FB_REQUIRED. ADR-055 §4 retires all four
# CYCLE_FB_* codes with the `cycle_feedback` kind itself; what they protected is
# now §1.5's single rule (INPUT_UNRESOLVED), which SPEC-6 exercises.

# ─── SPEC-5: the glob fan-in no longer NEEDS an exemption ───────────────────
# This used to pin a deliberate hole: review-aggregator declared `lens_results`
# (plural) while review-lens produced `lens_result` (singular), so id-matching
# was a false positive and the check had to be skipped for optional inputs.
# #1825 renamed the consumer to match the producer, which is the whole point of
# naming the artifact rather than the wire — the mismatch that needed excusing
# is gone. A map producer still yields a SET under the one id (ADR-055 §1.4).
_mk lensproducer "" '  - id: lens_result
    path: "${artifact_dir}/lens-${ZBUILD_REVIEW_LENS_ID}.json"
    type: review-lens.json'
_mk lensconsumer '  - id: lens_result
    required: false' ""
_out5="$(_validate lensproducer lensconsumer)"
assert_eq "[SPEC-5] a map fan-in resolves by name with no exemption" "" "$_out5"

# ─── SPEC-6: a REQUIRED input naming no producer still fails ────────────────
# ADR-055 §1.5. The optional carve-out (a plugin may declare inputs for gates a
# given template omits) must not become a hole for required ones.
_mk reqconsumer '  - id: not_declared_anywhere
    required: true' ""
_out6="$(_validate producer reqconsumer)"
if grep -q "INPUT_UNRESOLVED" <<< "$_out6"; then
    assert_pass "[SPEC-6] a required input naming no producer still fails"
else
    assert_fail "[SPEC-6] a required input naming no producer still fails" \
        "got: ${_out6:-<no violations>}"
fi

# [guard] and the optional carve-out is real, not blanket permissiveness.
_mk optconsumer '  - id: also_not_declared
    required: false' ""
_out7="$(_validate producer optconsumer)"
assert_eq "[SPEC-6] an OPTIONAL input naming no producer is allowed" "" "$_out7"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
