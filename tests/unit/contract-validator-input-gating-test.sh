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
    _raw "$@" | grep -E "BAD_SOURCE|MISSING_SOURCE|MISSING_STAGE|MISORDERED|SELF_REF|MISSING_OUTPUT|BAD_EXTERNAL|CYCLE_FB" || true
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
for _kind in "stage:<name>" "external" "artifacts" "cycle_feedback"; do
    if grep -qF "$_kind" <<< "$_msg"; then
        assert_pass "[SPEC-2] BAD_SOURCE message lists '$_kind'"
    else
        assert_fail "[SPEC-2] BAD_SOURCE message lists '$_kind'" "message: ${_msg:-<empty>}"
    fi
done

# ─── SPEC-3: source: artifacts is recognised, at both requirednesses ────────
# Nine live inputs use it (2 design, 7 gate-aggregator). Opening the gate
# without recognising it would refuse all nine and halt every run at pre-flight.
# TRANSITIONAL — ADR-055 §1 retires the kind; #1825 removes it.
_mk c3opt '  - id: some_artifact
    source: artifacts
    path: "some-file.json"
    required: false' ""
_mk c3req '  - id: other_artifact
    source: artifacts
    path: "${artifact_dir}/other.json"
    required: true' ""
_out3="$(_validate producer c3opt c3req)"
assert_eq "[SPEC-3] source: artifacts is accepted for required:false and required:true" "" "$_out3"

# ─── SPEC-4: a cycle_feedback rule that could never fire, now fires ─────────
# CYCLE_FB_DIR and CYCLE_FB_UNWIRED sat inside the required-only gate while this
# kind is REQUIRED to be optional, so neither could ever run. Worse for UNWIRED:
# lint-contract.sh:236-239 delegates it here ("runtime validator owns that"), so
# it was enforced by nobody.
_mk c4 '  - id: prior_thing
    type: text/plain
    path: "${artifact_dir}/prior-thing.txt"
    source: cycle_feedback
    required: false' ""
_out4="$(_validate producer c4)"
if grep -q "CYCLE_FB_DIR" <<< "$_out4"; then
    assert_pass "[SPEC-4] CYCLE_FB_DIR fires on an optional cycle_feedback input"
else
    assert_fail "[SPEC-4] CYCLE_FB_DIR fires on an optional cycle_feedback input" \
        "got: ${_out4:-<no violations>}"
fi

# ─── SPEC-5: the glob fan-in exemption SURVIVES ─────────────────────────────
# The one check that stays gated on required, deliberately. An optional input may
# be a glob fan-in over a producer GROUP, naming the producer for ordering rather
# than one output id — review-aggregator's lens_results globs lens-*.json across
# the review-lens members. This is the real shape: consumer names the plural, the
# producer declares the singular. Enforcing id-match here is a false positive,
# and the issue's proposed "validate optional inputs too" would have caused it.
_mk lensproducer "" '  - id: lens_result
    path: "${artifact_dir}/lens-${ZBUILD_REVIEW_LENS_ID}.json"
    type: review-lens.json'
_mk lensconsumer '  - id: lens_results
    type: glob
    path: "${artifact_dir}/lens-*.json"
    source: stage:lensproducer
    required: false' ""
_out5="$(_validate lensproducer lensconsumer)"
assert_eq "[SPEC-5] an optional glob fan-in is NOT reported as MISSING_OUTPUT" "" "$_out5"

# ─── SPEC-6: a REQUIRED input naming an undeclared output still fails ───────
# The exemption is scoped to optional inputs only; it must not become a hole.
_mk reqconsumer '  - id: not_declared_anywhere
    source: stage:producer
    required: true' ""
_out6="$(_validate producer reqconsumer)"
if grep -q "MISSING_OUTPUT" <<< "$_out6"; then
    assert_pass "[SPEC-6] a required input naming an undeclared output still fails"
else
    assert_fail "[SPEC-6] a required input naming an undeclared output still fails" \
        "got: ${_out6:-<no violations>}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
