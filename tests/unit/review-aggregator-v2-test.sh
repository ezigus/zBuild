#!/usr/bin/env bash
# tests/unit/review-aggregator-v2-test.sh
# Stage contract v2 acceptance tests for review-aggregator (#1842).
# All assertions tagged [#1842/SPEC-n] and must fail at baseline.
#
# SPEC-1[change]  manifest provides.result_contract == 2
# SPEC-2[change]  manifest config.valid_verdicts lists complete and degraded
# SPEC-3[change]  manifest outputs review_report_md declares required: true
# SPEC-4[change]  success-path writes result_contract:2 + verdict:complete + ...
# SPEC-5[change]  _ra_collect_lenses_glob and lens-* absent from plugin.sh
# SPEC-6[change]  review-report.md written on empty-lenses exit path
# SPEC-7[change]  SIGTERM/SIGINT writes degraded/interrupted and ends with rc 1
# SPEC-11[change] empty-lenses exit path writes result_contract:2 + verdict:complete + ...
# SPEC-12[guard]  manifest config: declares no router: key
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-aggregator — contract v2 (#1842)"
setup_test_env "review-aggregator-v2"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-aggregator"
MANIFEST="$PLUGIN_DIR/manifest.yaml"

# ── SPEC-1: manifest provides.result_contract: 2 ─────────────────────────────
assert_contains_regex "[#1842/SPEC-1] manifest declares result_contract: 2" \
    "$(cat "$MANIFEST")" '^  result_contract: 2$'

# ── SPEC-2: manifest config.valid_verdicts lists complete and degraded ────────
_vv="$(grep 'valid_verdicts:' "$MANIFEST")"
assert_contains "[#1842/SPEC-2] valid_verdicts lists complete" "$_vv" "complete"
assert_contains "[#1842/SPEC-2] valid_verdicts lists degraded" "$_vv" "degraded"

# ── SPEC-3: manifest outputs review_report_md declares required: true ────────
_rmd_required="$(awk '/id: review_report_md/{f=1} f && /required:/{print; exit}' "$MANIFEST")"
assert_contains "[#1842/SPEC-3] review_report_md declares required: true" "$_rmd_required" "true"

# ── Load plugin for runtime assertions ───────────────────────────────────────
# shellcheck source=../../plugins/agent/review-aggregator/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

_v2() { jq -r --arg k "$1" '.[$k] // empty' "$2" 2>/dev/null; }

# ── SPEC-4: success-path run writes v2 envelope ──────────────────────────────
_d4="$TEST_TEMP_DIR/s4"; mkdir -p "$_d4"
printf '%s\n' '{"schema_version":1,"name":"correctness","score":8,"findings":[]}' \
    > "$_d4/lens-correctness.json"
_si4="$TEST_TEMP_DIR/s4-inputs.json"
printf '{"inputs":{"lens_result":["%s"]}}\n' "$_d4/lens-correctness.json" > "$_si4"
set +e
ZBUILD_STAGE_INPUTS="$_si4" _review_aggregator_run_inner \
    "$_d4" "$_d4/review-report.json" "$_d4/review-report.md"
_rc4=$?
set -e
assert_eq "[#1842/SPEC-4] success-path rc=0" "0" "$_rc4"
assert_eq "[#1842/SPEC-4] result_contract is 2" "2" \
    "$(_v2 result_contract "$_d4/review-report.json")"
assert_eq "[#1842/SPEC-4] verdict=complete" "complete" \
    "$(_v2 verdict "$_d4/review-report.json")"
assert_eq "[#1842/SPEC-4] disposition=complete" "complete" \
    "$(_v2 disposition "$_d4/review-report.json")"
assert_contains_regex "[#1842/SPEC-4] reason is non-empty text" \
    "$(_v2 reason "$_d4/review-report.json")" '[a-z]'

# ── SPEC-5: _ra_collect_lenses_glob and lens-* absent from plugin.sh ─────────
if grep -q '_ra_collect_lenses_glob' "$PLUGIN_DIR/plugin.sh"; then
    assert_fail "[#1842/SPEC-5] _ra_collect_lenses_glob must be absent from plugin.sh" \
        "still present"
else
    assert_pass "[#1842/SPEC-5] _ra_collect_lenses_glob absent from plugin.sh"
fi
if grep -q 'lens-\*' "$PLUGIN_DIR/plugin.sh"; then
    assert_fail "[#1842/SPEC-5] lens-* wildcard must be absent from plugin.sh" \
        "still present"
else
    assert_pass "[#1842/SPEC-5] lens-* wildcard absent from plugin.sh"
fi

# ── SPEC-6: review-report.md written even when out_json is empty/unwritten ────
# Simulate _ra_aggregate producing no output so out_json stays zero-size.
# Baseline guards the md render on `[[ -s "$out_json" ]]` — if out_json is empty
# the md is skipped.  After the change the render is unconditional (using
# `cat "$out_json" 2>/dev/null || printf '{}'`), so the md is always written.
_ra_agg_s6_save="$(declare -f _ra_aggregate)"
# shellcheck disable=SC2317
_ra_aggregate() { : ; }
_d6="$TEST_TEMP_DIR/s6"; mkdir -p "$_d6"
_si6="$TEST_TEMP_DIR/s6-inputs.json"
printf '{"inputs":{"lens_result":[]}}\n' > "$_si6"
set +e
ZBUILD_STAGE_INPUTS="$_si6" _review_aggregator_run_inner \
    "$_d6" "$_d6/review-report.json" "$_d6/review-report.md"
set -e
eval "$_ra_agg_s6_save" 2>/dev/null || true
assert_file_exists "[#1842/SPEC-6] review-report.md written even when out_json is empty/unwritten" \
    "$_d6/review-report.md"

# ── SPEC-11: empty-lenses exit path writes v2 envelope ───────────────────────
_d11="$TEST_TEMP_DIR/s11"; mkdir -p "$_d11"
_si11="$TEST_TEMP_DIR/s11-inputs.json"
printf '{"inputs":{"lens_result":[]}}\n' > "$_si11"
set +e
ZBUILD_STAGE_INPUTS="$_si11" _review_aggregator_run_inner \
    "$_d11" "$_d11/review-report.json" "$_d11/review-report.md"
set -e
assert_eq "[#1842/SPEC-11] empty-lenses result_contract is 2" "2" \
    "$(_v2 result_contract "$_d11/review-report.json")"
assert_eq "[#1842/SPEC-11] empty-lenses verdict=complete" "complete" \
    "$(_v2 verdict "$_d11/review-report.json")"
assert_eq "[#1842/SPEC-11] empty-lenses disposition=complete" "complete" \
    "$(_v2 disposition "$_d11/review-report.json")"
assert_contains_regex "[#1842/SPEC-11] empty-lenses reason is non-empty text" \
    "$(_v2 reason "$_d11/review-report.json")" '[a-z]'

# ── SPEC-7: SIGTERM trap writes verdict:degraded + disposition:interrupted ────
# Override _ra_aggregate to pause so the signal can be delivered while the inner
# function is running and its trap is active. The sentinel file confirms the
# function has started and the trap is registered before we send SIGTERM.
_d7="$TEST_TEMP_DIR/s7"; mkdir -p "$_d7"
_si7="$TEST_TEMP_DIR/s7-inputs.json"
printf '{"inputs":{"lens_result":[]}}\n' > "$_si7"
_ra_agg_save="$(declare -f _ra_aggregate)"
_trap_sentinel="$TEST_TEMP_DIR/s7-ready"
# shellcheck disable=SC2317  # invoked indirectly through the plugin's call to _ra_aggregate
_ra_aggregate() {
    touch "$_trap_sentinel"
    local _sp
    sleep 20 & _sp=$!; wait "$_sp"
    printf '{}'
}
set +e
ZBUILD_STAGE_INPUTS="$_si7" _review_aggregator_run_inner \
    "$_d7" "$_d7/review-report.json" "$_d7/review-report.md" &
_sig_pid=$!
_wi=0
while [[ ! -f "$_trap_sentinel" && "$_wi" -lt 40 ]]; do
    if ! kill -0 "$_sig_pid" 2>/dev/null; then break; fi
    sleep 0.1
    _wi=$(( _wi + 1 ))
done
kill -SIGTERM "$_sig_pid" 2>/dev/null || true
wait "$_sig_pid" 2>/dev/null
_sig_rc=$?
set -e
eval "$_ra_agg_save" 2>/dev/null || true
assert_eq "[#1842/SPEC-7] SIGTERM ends the stage with rc 1" "1" "$_sig_rc"
assert_eq "[#1842/SPEC-7] interrupted writes verdict:degraded" "degraded" \
    "$(_v2 verdict "$_d7/review-report.json")"
assert_eq "[#1842/SPEC-7] interrupted writes disposition:interrupted" "interrupted" \
    "$(_v2 disposition "$_d7/review-report.json")"
assert_file_exists "[#1842/SPEC-7] summary written on SIGTERM path" \
    "$_d7/review-report.md"

# ── SPEC-12: manifest config: section declares no router: key ─────────────────
_config_block="$(awk '/^config:/{f=1; next} f && /^[^ ]/{f=0} f{print}' "$MANIFEST")"
if grep -q 'router:' <<< "$_config_block"; then
    assert_fail "[#1842/SPEC-12] manifest config: must declare no router: key" \
        "found router:"
else
    assert_pass \
        "[#1842/SPEC-12] manifest config: declares no router: key (ADR-017 §11 not applicable)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
