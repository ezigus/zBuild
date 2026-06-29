#!/usr/bin/env bash
# Tests: the inter-stage data-contract PREFLIGHT (core/pipeline/contract-validator.sh
# _contract_validate_pipeline) is satisfiable for every SHIPPED template.
#
# Regression guard for #1142: the C3 lens cutover replaced simple.yaml's `review`
# stage with `review-aggregator`, but pr-delivery still hard-required `review`
# (review.json from stage:review) → preflight_failed at `pipeline start`. The
# roster tests passed; nothing exercised the RUNTIME contract. This test runs the
# validator in enforce mode against simple.yaml + standard.yaml and asserts every
# required input has a producer in the template (so a future cutover that strands
# a required input fails HERE, not in a user's dogfood). ADR-020.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "preflight inter-stage contract — shipped templates (#1142 regression, ADR-020)"
setup_test_env "preflight-contract-templates"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_ISSUE=1

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

for _tpl in simple standard; do
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
        assert_pass "[$_tpl.yaml] preflight contract satisfied — every required input has a producer"
    else
        assert_fail "[$_tpl.yaml] preflight contract satisfied — every required input has a producer" \
            "validator rc=$_rc: $(printf '%s' "$_cv_out" | tr '\n' '|' | head -c 500)"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
