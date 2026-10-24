#!/usr/bin/env bash
# Tests: the inter-stage data-contract PREFLIGHT (core/pipeline/contract-validator.sh
# _contract_validate_pipeline) is satisfiable for every SHIPPED template.
#
# Regression guard for #1142: the C3 lens cutover replaced simple.yaml's `review`
# stage with `review-aggregator`, but pr-delivery still hard-required `review`
# (review.json from stage:review) → preflight_failed at `pipeline start`. The
# roster tests passed; nothing exercised the RUNTIME contract. This test runs the
# validator in enforce mode against every SHIPPED template (simple.yaml — the sole
# shipped template after #979 retired standard.yaml) and asserts the template
# satisfies it — every stage's manifest is well-formed and declares no inputs
# (ADR-055 §1, amended 2026-10-12), and the aggregator wiring is right — so a
# future change that breaks it fails HERE, not in a user's dogfood. ADR-020.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "preflight inter-stage contract — shipped templates (#1142 regression, ADR-020)"
setup_test_env "preflight-contract-templates"

# #1921 follow-up: reserved test identity (zb_test_issue). These were real
# issue numbers; a run keyed to one writes fabricated prior work onto that
# issue's state branch. Only identity positions and the strings DERIVED from
# them are swept — a bare number elsewhere is not an identity.
_ZB_ID="$(zb_test_issue)"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_ISSUE="$_ZB_ID"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"
# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

for _tpl in simple deployed; do
    load_template "$REPO_ROOT/config/templates/$_tpl.yaml" >/dev/null 2>&1
    _stages_nl="$(printf '%s\n' "${_TPL_STAGES[@]}")"
    _sf="$TEST_TEMP_DIR/$_tpl-state/pipeline-state.json"
    mkdir -p "$(dirname "$_sf")"
    set +e
    # Capture the validator's diagnostic so a failure names the stranded
    # stage/input (the whole point of this guard) rather than just "expected 0".
    _cv_out="$(ZBUILD_CONTRACT_VALIDATOR=enforce \
        _contract_validate_pipeline "$_stages_nl" "$REPO_ROOT/plugins" "$_sf" 2>&1)"
    _rc=$?
    set -e
    if [[ "$_rc" -eq 0 ]]; then
        assert_pass "[$_tpl.yaml] preflight contract satisfied"
    else
        assert_fail "[$_tpl.yaml] preflight contract satisfied" \
            "validator rc=$_rc: $(printf '%s' "$_cv_out" | tr '\n' '|' | head -c 500)"
    fi
done

# ─── Phase 1 (ADR-040 §3/§5): typed-aggregator preflight — fail-loud cases ─────
# The validator reads the template parser side-channels (_TPL_CYCLES / _TPL_PARALLEL_*)
# directly, so we inject them here against a minimal fixture plugins root that
# carries the `convergence:` markers — no need to author a fully-loadable template.
print_test_section "typed-aggregator preflight (ADR-040 §3/§5)"

FX_ROOT="$TEST_TEMP_DIR/fxplugins"
mkdir -p "$FX_ROOT/tool/g_gate" "$FX_ROOT/agent/l_adv" "$FX_ROOT/agent/l_agg"
# write_fx <dir> <id> <kind> <convergence|""> <role> <out_id>
write_fx() {
    {
        printf 'id: %s\n' "$2"; printf 'name: %s\n' "$2"; printf 'kind: %s\n' "$3"
        [[ -n "$4" ]] && printf 'convergence: %s\n' "$4"
        printf 'version: 0.1.0\nhooks:\n  run: r\n'
        printf 'provides:\n  role: %s\n' "$5"
        printf 'outputs:\n  - id: %s\n    type: %s.json@1\n    format: json\n    path: ${artifact_dir}/%s.json\n    required: true\n    primary: true\n' "$6" "$6" "$6"
        # ADR-055 §9 (#2000): every stage-bound plugin declares exactly one
        # summary. A fixture that omits it is refused at pre-flight, which is
        # the contract working — so the fixture declares one too.
        printf '  - id: %s_summary\n    type: %s-summary.md@1\n    format: markdown\n    path: ${artifact_dir}/%s-summary.md\n    required: true\n    summary: true\n' "$6" "$6" "$6"
    } > "$1/manifest.yaml"
}
write_fx "$FX_ROOT/tool/g_gate" g_gate tool  gate     g_gate g_gate_result
write_fx "$FX_ROOT/agent/l_adv" l_adv  agent advisory l_adv  l_adv_result
write_fx "$FX_ROOT/agent/l_agg" l_agg  agent advisory l_agg  l_agg_result

_reset_tpl_state() { _TPL_CYCLES=(); _TPL_PARALLEL_GROUPS=(); }
_run_fx_validator() {
    local stages="$1" sf="$TEST_TEMP_DIR/fx-state/state.json"
    mkdir -p "$(dirname "$sf")"; rm -f "$sf"
    set +e
    FX_OUT="$(ZBUILD_CONTRACT_VALIDATOR=enforce \
        _contract_validate_pipeline "$stages" "$FX_ROOT" "$sf" 2>&1)"
    FX_RC=$?
    set -e
}

# FAIL-A/FAIL-B retired (#2368): the typed-aggregator preflight is gone with the
# `convergence:` marker; a loop's exit_when names its must-pass members.

# PASS: same group WITH an explicit non-member advisory aggregator (l_agg) → rc=0.
_reset_tpl_state
_TPL_PARALLEL_GROUPS=(p1)
export _TPL_PARALLEL_AGGREGATE_p1="advisory"
export _TPL_PARALLEL_FLOW_p1="l_adv"
_run_fx_validator "$(printf 'l_adv\nl_agg\n')"
assert_eq "PASS: advisory group + explicit aggregator → preflight passes (rc=0)" "0" "$FX_RC"
unset _TPL_PARALLEL_AGGREGATE_p1 _TPL_PARALLEL_FLOW_p1
_reset_tpl_state

cleanup_test_env
print_test_results
exit $((FAIL > 0))
