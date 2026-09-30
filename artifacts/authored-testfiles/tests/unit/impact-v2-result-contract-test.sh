#!/usr/bin/env bash
# Tests: impact plugin v2 result contract (issue #1838).
# SPEC-1  [change]: impact_run writes result_contract:2 on every early-exit path
#                   (missing ZBUILD_ARTIFACT_DIR → broken/broken,
#                    missing required input → broken/broken)
# SPEC-2  [change]: impact_run installs a stage_signal_begin guard; an
#                   interruption before any result is written produces
#                   result_contract:2 with disposition=interrupted, reason=signal_interrupt
# SPEC-3  [change]: _impact_run_inner writes result_contract:2 on router failure
#                   paths with disposition from router_reason_disposition and
#                   reason from the router rc classifier (no router_rc field)
# SPEC-4  [change]: _impact_run_inner writes result_contract:2 on the success
#                   path with disposition=complete and reason populated from the
#                   verdict summary
# SPEC-5  [change]: manifest.yaml declares result_contract: 2 under provides
# SPEC-6  [change]: manifest.yaml declares a config.router block with
#                   timeout_s: 600 and max_turns: 45
# SPEC-7  [change]: impact_run reads scope_manifest, design, and plan input
#                   paths from ZBUILD_STAGE_INPUTS (the engine's index) rather
#                   than constructing them from the state_file argument
# SPEC-13 [guard]:  when impact's manifest declares config.router.timeout_s: 600
#                   and a per-stage template accessor returns a different value,
#                   _route_resolve_timeout returns the template value (template >
#                   manifest precedence preserved per _route_resolve_knob)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "impact: v2 result contract — impact.json on all exit paths (#1838)"
setup_test_env "impact-v2-result-contract"

# Source the impact plugin so real dependencies load, then override mocks.
# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

# Global mocks applied after sourcing so they shadow the real implementations.
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { cat > "$1"; }
emit_event() { return 0; }
warn() { return 0; }
stage_summary_write() { return 0; }

_IMPACT_MF="$REPO_ROOT/plugins/agent/impact/manifest.yaml"

# _setup_fixture <id> — build a minimal temp state tree and export env vars.
# Sets: _F_STATE _F_ARTIFACTS _F_STATE_FILE _F_SCOPE _F_DESIGN _F_PLAN _F_IMPACT
_setup_fixture() {
    local _id="$1"
    local _base="$TEST_TEMP_DIR/$_id"
    rm -rf "$_base"
    local _state="$_base/state"
    local _artifacts="$_state/artifacts"
    mkdir -p "$_artifacts"

    printf 'scope: all\n' > "$_state/scope-manifest.md"
    printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$_artifacts/design.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' \
        > "$_artifacts/plan.json"

    printf '{}' > "$_state/pipeline-state.json"

    export ZBUILD_EVENTS_JSONL="$_base/events.jsonl"
    export ZBUILD_EVENTS_DIR="$_base"
    export ZBUILD_REPO_ROOT="$_base"
    mkdir -p "$ZBUILD_REPO_ROOT/config"
    : > "$ZBUILD_EVENTS_JSONL"

    _F_STATE="$_state"
    _F_ARTIFACTS="$_artifacts"
    _F_STATE_FILE="$_state/pipeline-state.json"
    _F_SCOPE="$_state/scope-manifest.md"
    _F_DESIGN="$_artifacts/design.md"
    _F_PLAN="$_artifacts/plan.json"
    _F_IMPACT="$_artifacts/impact.json"
}

# ─── SPEC-5: manifest declares result_contract:2 under provides ───────────────

# result_contract: 2 must appear within the provides: section, not just anywhere.
_mf_rc2="$(awk '/^provides:/{f=1;next} f && /^[[:alpha:]]/{f=0} f && /result_contract:/{print $2;exit}' "$_IMPACT_MF" 2>/dev/null || true)"
assert_eq "[#1838/SPEC-5] manifest provides.result_contract=2 (under provides)" "2" "${_mf_rc2:-MISSING}"

# ─── SPEC-6: manifest declares config.router block with timeout_s/max_turns ──
# Both values must appear within the config.router sub-block specifically.
_router_block="$(awk '/^  router:/{f=1;next} f && /^  [^[:space:]-]/{f=0} f{print}' "$_IMPACT_MF" 2>/dev/null || true)"
if grep -q 'timeout_s:[[:space:]]*600' <<< "$_router_block" 2>/dev/null; then
    assert_pass "[#1838/SPEC-6] manifest config.router.timeout_s=600"
else
    assert_fail "[#1838/SPEC-6] manifest config.router.timeout_s=600" \
        "no timeout_s: 600 in config.router block of $_IMPACT_MF"
fi
if grep -q 'max_turns:[[:space:]]*45' <<< "$_router_block" 2>/dev/null; then
    assert_pass "[#1838/SPEC-6] manifest config.router.max_turns=45"
else
    assert_fail "[#1838/SPEC-6] manifest config.router.max_turns=45" \
        "no max_turns: 45 in config.router block of $_IMPACT_MF"
fi

# ─── SPEC-1: impact_run writes result_contract:2 on every early-exit path ────

# Path A: missing ZBUILD_ARTIFACT_DIR → impact_run writes broken/broken to
# a state-file-derived fallback (the only write path available without an
# explicit artifact dir). SPEC-1 requires the write; this asserts where it goes.
_setup_fixture spec1a
unset ZBUILD_ARTIFACT_DIR
_S1A_INPUTS="$TEST_TEMP_DIR/spec1a_inputs.json"
printf '{"inputs":{"scope_manifest":"%s","design":"%s","plan":"%s"}}\n' \
    "$_F_SCOPE" "$_F_DESIGN" "$_F_PLAN" > "$_S1A_INPUTS"
export ZBUILD_STAGE_INPUTS="$_S1A_INPUTS"
# Neutralise signal guard for this path test.
stage_signal_begin() { return 0; }
stage_signal_end() { return 0; }

_rc_s1a=0
impact_run "impact" "$_F_STATE_FILE" 2>/dev/null || _rc_s1a=$?
unset ZBUILD_STAGE_INPUTS

assert_eq "[#1838/SPEC-1] missing ZBUILD_ARTIFACT_DIR → rc=1" "1" "$_rc_s1a"
_s1a_rc2="$(jq -r '.result_contract // "MISSING"' "$_F_IMPACT" 2>/dev/null || echo MISSING)"
_s1a_verdict="$(jq -r '.verdict // "MISSING"' "$_F_IMPACT" 2>/dev/null || echo MISSING)"
_s1a_disp="$(jq -r '.disposition // "MISSING"' "$_F_IMPACT" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-1] missing ZBUILD_ARTIFACT_DIR → result_contract=2" "2" "$_s1a_rc2"
assert_eq "[#1838/SPEC-1] missing ZBUILD_ARTIFACT_DIR → verdict=broken" "broken" "$_s1a_verdict"
assert_eq "[#1838/SPEC-1] missing ZBUILD_ARTIFACT_DIR → disposition=broken" "broken" "$_s1a_disp"
_s1a_reason="$(jq -r '.reason // "MISSING"' "$_F_IMPACT" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-1] missing ZBUILD_ARTIFACT_DIR → reason=missing_artifact_dir" \
    "missing_artifact_dir" "$_s1a_reason"

# Path B: ZBUILD_ARTIFACT_DIR is set but a required input is missing from the
# engine's index (scope_manifest not named) → broken/broken.
_setup_fixture spec1b
export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/spec1b_artifacts"
mkdir -p "$ZBUILD_ARTIFACT_DIR"
_S1B_INPUTS="$TEST_TEMP_DIR/spec1b_inputs.json"
# scope_manifest is absent — required input missing.
printf '{"inputs":{"design":"%s","plan":"%s"}}\n' "$_F_DESIGN" "$_F_PLAN" > "$_S1B_INPUTS"
export ZBUILD_STAGE_INPUTS="$_S1B_INPUTS"

_rc_s1b=0
impact_run "impact" "$_F_STATE_FILE" 2>/dev/null || _rc_s1b=$?
unset ZBUILD_ARTIFACT_DIR ZBUILD_STAGE_INPUTS

assert_eq "[#1838/SPEC-1] missing required input → rc=1" "1" "$_rc_s1b"
_s1b_out="$TEST_TEMP_DIR/spec1b_artifacts/impact.json"
_s1b_rc2="$(jq -r '.result_contract // "MISSING"' "$_s1b_out" 2>/dev/null || echo MISSING)"
_s1b_disp="$(jq -r '.disposition // "MISSING"' "$_s1b_out" 2>/dev/null || echo MISSING)"
_s1b_verdict="$(jq -r '.verdict // "MISSING"' "$_s1b_out" 2>/dev/null || echo MISSING)"
_s1b_reason="$(jq -r '.reason // "MISSING"' "$_s1b_out" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-1] missing required input → result_contract=2" "2" "$_s1b_rc2"
assert_eq "[#1838/SPEC-1] missing required input → verdict=broken" "broken" "$_s1b_verdict"
assert_eq "[#1838/SPEC-1] missing required input → disposition=broken" "broken" "$_s1b_disp"
assert_eq "[#1838/SPEC-1] missing required input → reason=input_missing" "input_missing" "$_s1b_reason"

# ─── SPEC-2: stage_signal_begin guard; signal → interrupted/signal_interrupt ──

_setup_fixture spec2
export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/spec2_artifacts"
mkdir -p "$ZBUILD_ARTIFACT_DIR"
_S2_INPUTS="$TEST_TEMP_DIR/spec2_inputs.json"
printf '{"inputs":{"scope_manifest":"%s","design":"%s","plan":"%s"}}\n' \
    "$_F_SCOPE" "$_F_DESIGN" "$_F_PLAN" > "$_S2_INPUTS"

_S2_ARTIFACTS="$TEST_TEMP_DIR/spec2_artifacts"
# Run in a subshell so stage_signal_begin can fire the callback immediately
# before any result is written — simulates an OS signal interrupting the stage.
(
    export ZBUILD_ARTIFACT_DIR="$_S2_ARTIFACTS"
    export ZBUILD_STAGE_INPUTS="$_S2_INPUTS"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/spec2_events.jsonl"
    : > "$ZBUILD_EVENTS_JSONL"
    _ZB_SIGNAL_CB=""
    atomic_write() { cat > "$1"; }
    apply_scope_redaction() { cp "$1" "$2"; return 0; }
    emit_event() { return 0; }
    stage_summary_write() { return 0; }
    # Override stage_signal_begin: capture callback and fire it immediately
    # (simulates a signal arriving before any result is written).
    stage_signal_begin() {
        local _cb="$1"
        stage_signal_end() { return 0; }
        "$_cb" "$STAGE_SIGNAL_DISPOSITION" "$STAGE_SIGNAL_REASON" || true
        return 0
    }
    impact_run "impact" "$_F_STATE_FILE" 2>/dev/null || true
) 2>/dev/null || true

unset ZBUILD_ARTIFACT_DIR ZBUILD_STAGE_INPUTS

_s2_rc2="$(jq -r '.result_contract // "MISSING"' "$_S2_ARTIFACTS/impact.json" 2>/dev/null || echo MISSING)"
_s2_verdict="$(jq -r '.verdict // "MISSING"' "$_S2_ARTIFACTS/impact.json" 2>/dev/null || echo MISSING)"
_s2_disp="$(jq -r '.disposition // "MISSING"' "$_S2_ARTIFACTS/impact.json" 2>/dev/null || echo MISSING)"
_s2_reason="$(jq -r '.reason // "MISSING"' "$_S2_ARTIFACTS/impact.json" 2>/dev/null || echo MISSING)"

assert_eq "[#1838/SPEC-2] signal before result → result_contract=2" "2" "$_s2_rc2"
assert_eq "[#1838/SPEC-2] signal before result → verdict=error" "error" "$_s2_verdict"
assert_eq "[#1838/SPEC-2] signal before result → disposition=interrupted" "interrupted" "$_s2_disp"
assert_eq "[#1838/SPEC-2] signal before result → reason=signal_interrupt" "signal_interrupt" "$_s2_reason"

# ─── SPEC-3: _impact_run_inner writes result_contract:2 on router failure ─────
# disposition comes from router_reason_disposition; no router_rc field in v2.

_setup_fixture spec3
mkdir -p "$TEST_TEMP_DIR/spec3_artifacts"
_S3_IMPACT="$TEST_TEMP_DIR/spec3_artifacts/impact.json"

# rc=124 (timeout): disposition=timed_out, reason=router_timeout, no router_rc.
route_to_model() { return 124; }
_rc_s3a=0
_impact_run_inner "$_F_SCOPE" "$_F_DESIGN" "$_F_PLAN" "$_S3_IMPACT" \
    "$TEST_TEMP_DIR/spec3_artifacts" 2>/dev/null || _rc_s3a=$?

assert_eq "[#1838/SPEC-3] rc=124 → _impact_run_inner returns rc=0 (graceful)" "0" "$_rc_s3a"
assert_file_exists "[#1838/SPEC-3] rc=124 → impact.json written" "$_S3_IMPACT"

_s3a_rc2="$(jq -r '.result_contract // "MISSING"' "$_S3_IMPACT" 2>/dev/null || echo MISSING)"
_s3a_disp="$(jq -r '.disposition // "MISSING"' "$_S3_IMPACT" 2>/dev/null || echo MISSING)"
_s3a_reason="$(jq -r '.reason // "MISSING"' "$_S3_IMPACT" 2>/dev/null || echo MISSING)"
_s3a_has_router_rc="$(jq -r 'has("router_rc")' "$_S3_IMPACT" 2>/dev/null || echo true)"

assert_eq "[#1838/SPEC-3] rc=124 → result_contract=2" "2" "$_s3a_rc2"
assert_eq "[#1838/SPEC-3] rc=124 → disposition=timed_out (from router_reason_disposition)" \
    "timed_out" "$_s3a_disp"
assert_eq "[#1838/SPEC-3] rc=124 → reason=router_timeout (from rc classifier)" \
    "router_timeout" "$_s3a_reason"
assert_eq "[#1838/SPEC-3] rc=124 → no router_rc field in v2 result" "false" "$_s3a_has_router_rc"

# rc=137 (OOM kill): disposition=interrupted, reason=router_oom_kill, no router_rc.
route_to_model() { return 137; }
rm -f "$_S3_IMPACT"
_rc_s3b=0
_impact_run_inner "$_F_SCOPE" "$_F_DESIGN" "$_F_PLAN" "$_S3_IMPACT" \
    "$TEST_TEMP_DIR/spec3_artifacts" 2>/dev/null || _rc_s3b=$?

assert_eq "[#1838/SPEC-3] rc=137 → _impact_run_inner returns rc=0" "0" "$_rc_s3b"
_s3b_rc2="$(jq -r '.result_contract // "MISSING"' "$_S3_IMPACT" 2>/dev/null || echo MISSING)"
_s3b_disp="$(jq -r '.disposition // "MISSING"' "$_S3_IMPACT" 2>/dev/null || echo MISSING)"
_s3b_has_router_rc="$(jq -r 'has("router_rc")' "$_S3_IMPACT" 2>/dev/null || echo true)"
_s3b_reason="$(jq -r '.reason // "MISSING"' "$_S3_IMPACT" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-3] rc=137 → result_contract=2" "2" "$_s3b_rc2"
assert_eq "[#1838/SPEC-3] rc=137 → disposition=interrupted (router_oom_kill)" \
    "interrupted" "$_s3b_disp"
assert_eq "[#1838/SPEC-3] rc=137 → reason=router_oom_kill (from rc classifier)" \
    "router_oom_kill" "$_s3b_reason"
assert_eq "[#1838/SPEC-3] rc=137 → no router_rc field in v2 result" "false" "$_s3b_has_router_rc"

# ─── SPEC-4: _impact_run_inner success path writes result_contract:2 ──────────
# disposition=complete, reason non-empty.

_setup_fixture spec4
mkdir -p "$TEST_TEMP_DIR/spec4_artifacts"
_S4_IMPACT="$TEST_TEMP_DIR/spec4_artifacts/impact.json"

route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"complete","missing":[]}'
    return 0
}
_rc_s4=0
_impact_run_inner "$_F_SCOPE" "$_F_DESIGN" "$_F_PLAN" "$_S4_IMPACT" \
    "$TEST_TEMP_DIR/spec4_artifacts" 2>/dev/null || _rc_s4=$?

assert_eq "[#1838/SPEC-4] success path → rc=0" "0" "$_rc_s4"
assert_file_exists "[#1838/SPEC-4] success path → impact.json written" "$_S4_IMPACT"

_s4_rc2="$(jq -r '.result_contract // "MISSING"' "$_S4_IMPACT" 2>/dev/null || echo MISSING)"
_s4_disp="$(jq -r '.disposition // "MISSING"' "$_S4_IMPACT" 2>/dev/null || echo MISSING)"
_s4_reason="$(jq -r '.reason // "MISSING"' "$_S4_IMPACT" 2>/dev/null || echo MISSING)"

assert_eq "[#1838/SPEC-4] success path → result_contract=2" "2" "$_s4_rc2"
assert_eq "[#1838/SPEC-4] success path → disposition=complete" "complete" "$_s4_disp"
# reason must be populated FROM the verdict summary — for verdict=complete with
# empty missing[], the plugin encodes this as "verdict:complete".
assert_eq "[#1838/SPEC-4] success path → reason from verdict summary (verdict:complete)" \
    "verdict:complete" "$_s4_reason"

# ─── SPEC-7: impact_run reads inputs from ZBUILD_STAGE_INPUTS ─────────────────
# Inputs placed at NON-DEFAULT paths; default v1 paths absent — only
# ZBUILD_STAGE_INPUTS paths can work.  A spy on _impact_run_inner captures the
# actual scope_manifest arg to verify the engine's index was used, not a
# state_file-derived path.

_setup_fixture spec7

# Inputs at custom paths (not where state_file-derived logic would look).
_S7_SCOPE="$TEST_TEMP_DIR/spec7_custom_scope.md"
_S7_DESIGN="$TEST_TEMP_DIR/spec7_custom_design.md"
_S7_PLAN="$TEST_TEMP_DIR/spec7_custom_plan.json"
printf 'scope: custom\n' > "$_S7_SCOPE"
printf '# Design\n\n```scope\nbar.sh\n```\n' > "$_S7_DESIGN"
printf '{"schema_version":1,"title":"custom","goal":"g","steps":[{"id":"s1","description":"d","files":["bar.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' \
    > "$_S7_PLAN"

_S7_INPUTS="$TEST_TEMP_DIR/spec7_inputs.json"
printf '{"inputs":{"scope_manifest":"%s","design":"%s","plan":"%s"}}\n' \
    "$_S7_SCOPE" "$_S7_DESIGN" "$_S7_PLAN" > "$_S7_INPUTS"

# Delete default-path files so a state_file-path-constructing plugin cannot succeed.
rm -f "$_F_SCOPE" "$_F_DESIGN" "$_F_PLAN"

# Spy: capture all three input paths ($1=$scope, $2=$design, $3=$plan) passed by
# impact_run → _impact_run_inner. Proves the engine's input index is used for
# all three inputs, not state_file-derived path construction.
_s7_spy_scope_file="$TEST_TEMP_DIR/spec7_spy_scope.txt"
_s7_spy_design_file="$TEST_TEMP_DIR/spec7_spy_design.txt"
_s7_spy_plan_file="$TEST_TEMP_DIR/spec7_spy_plan.txt"
_impact_run_inner() {
    printf '%s' "$1" > "$_s7_spy_scope_file"
    printf '%s' "$2" > "$_s7_spy_design_file"
    printf '%s' "$3" > "$_s7_spy_plan_file"
    # Write a valid v2 impact.json so impact_run accepts success
    printf '{"result_contract":2,"verdict":"complete","disposition":"complete","reason":"verdict:complete","schema_version":1,"missing":[]}\n' \
        > "${4:-/dev/null}"
    _IMPACT_RESULT_WRITTEN=1
    return 0
}

export ZBUILD_STAGE_INPUTS="$_S7_INPUTS"
export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/spec7_artifacts"
mkdir -p "$ZBUILD_ARTIFACT_DIR"

stage_signal_begin() { return 0; }
stage_signal_end() { return 0; }

_rc_s7=0
impact_run "impact" "$_F_STATE_FILE" 2>/dev/null || _rc_s7=$?

unset ZBUILD_ARTIFACT_DIR ZBUILD_STAGE_INPUTS

assert_eq "[#1838/SPEC-7] impact_run succeeds using ZBUILD_STAGE_INPUTS paths (rc=0)" "0" "$_rc_s7"
_s7_received_scope="$(cat "$_s7_spy_scope_file" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-7] scope_manifest path from ZBUILD_STAGE_INPUTS (not state_file)" \
    "$_S7_SCOPE" "$_s7_received_scope"
_s7_received_design="$(cat "$_s7_spy_design_file" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-7] design path from ZBUILD_STAGE_INPUTS (not state_file)" \
    "$_S7_DESIGN" "$_s7_received_design"
_s7_received_plan="$(cat "$_s7_spy_plan_file" 2>/dev/null || echo MISSING)"
assert_eq "[#1838/SPEC-7] plan path from ZBUILD_STAGE_INPUTS (not state_file)" \
    "$_S7_PLAN" "$_s7_received_plan"

# ─── SPEC-13: template accessor beats manifest config.router.timeout_s ────────
# When impact's manifest declares config.router.timeout_s: 600 and a per-stage
# template accessor returns a different value, the template value wins
# (_route_resolve_knob precedence: template > env > manifest > constant).

unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS_OVERRIDE 2>/dev/null || true
export ZBUILD_CURRENT_STAGE="impact"
export ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/impact"
export ZBUILD_YAML_CACHE=0

# Template accessor returns 300 — different from the manifest's 600.
template_stage_router_timeout() {
    [[ "${1:-}" == "impact" ]] && printf '300\n' || return 1
}

_s13_got="$(_route_resolve_timeout)"
assert_eq "[#1838/SPEC-13] template (300) beats manifest default (600)" "300" "$_s13_got"

unset ZBUILD_CURRENT_STAGE ZBUILD_PLUGIN_DIR ZBUILD_YAML_CACHE
unset -f template_stage_router_timeout 2>/dev/null || true

# ─── SPEC-14: provides.events lists all nine impact events ────────────────────
# Pre-existing declaration guarded against regression by the v2 migration.

_s14_events_block="$(awk '/^  events:/{f=1;next} f && (/^  [^[:space:]-]/ || /^[^[:space:]]/){f=0} f{print}' "$_IMPACT_MF" 2>/dev/null || true)"
for _s14_ev in \
    "impact.contract.violation" \
    "impact.envelope.malformed" \
    "impact.envelope.recovered" \
    "impact.hallucination.filtered" \
    "impact.scope.expanded" \
    "impact.scope.plateau" \
    "impact.verdict.complete" \
    "impact.verdict.error" \
    "impact.verdict.incomplete"; do
    if grep -qF -- "- $_s14_ev" <<< "$_s14_events_block" 2>/dev/null; then
        assert_pass "[#1838/SPEC-14] provides.events includes $_s14_ev"
    else
        assert_fail "[#1838/SPEC-14] provides.events includes $_s14_ev" \
            "$_s14_ev not listed in provides.events of $_IMPACT_MF"
    fi
done

# ─── SPEC-15: provides.role: impact_analyzer ─────────────────────────────────

_s15_role="$(awk '/^provides:/{f=1;next} f && /^[[:alpha:]]/{f=0} f && /^ *role:/{print $2;exit}' "$_IMPACT_MF" 2>/dev/null || true)"
assert_eq "[#1838/SPEC-15] manifest provides.role=impact_analyzer" \
    "impact_analyzer" "${_s15_role:-MISSING}"

# ─── SPEC-16: hooks block records cleanup absence with reason comment ──────────
# Per #1829: absence is recorded, not implied.

_s16_hooks_block="$(awk '/^hooks:/{f=1;next} f && /^[[:alpha:]]/{f=0} f{print}' "$_IMPACT_MF" 2>/dev/null || true)"
# No cleanup: key defined in hooks.
if grep -qE '^[[:space:]]*cleanup:' "$_IMPACT_MF" 2>/dev/null; then
    assert_fail "[#1838/SPEC-16] hooks block has no cleanup: hook defined" \
        "cleanup: key found in manifest"
else
    assert_pass "[#1838/SPEC-16] hooks block has no cleanup: hook defined"
fi
# Absence recorded with a comment mentioning "no live resources".
_s16_has_comment=0
_s16_has_reason=0
grep -qi 'cleanup' <<< "$_s16_hooks_block" 2>/dev/null && _s16_has_comment=1 || true
grep -qi 'no live resources' <<< "$_s16_hooks_block" 2>/dev/null && _s16_has_reason=1 || true
if [[ "$_s16_has_comment" -eq 1 && "$_s16_has_reason" -eq 1 ]]; then
    assert_pass "[#1838/SPEC-16] hooks block records cleanup absence with 'no live resources' reason"
else
    assert_fail "[#1838/SPEC-16] hooks block records cleanup absence with 'no live resources' reason" \
        "cleanup_comment=${_s16_has_comment} no_live_resources=${_s16_has_reason}"
fi

# ─── SPEC-17: valid_verdicts covers all emitted verdicts ──────────────────────

_s17_vv_block="$(awk '/^  valid_verdicts:/{f=1;next} f && (/^  [^[:space:]-]/ || /^[^[:space:]]/){f=0} f{print}' "$_IMPACT_MF" 2>/dev/null || true)"
for _s17_vv in "complete" "incomplete" "error"; do
    if grep -qF -- "- $_s17_vv" <<< "$_s17_vv_block" 2>/dev/null; then
        assert_pass "[#1838/SPEC-17] manifest valid_verdicts includes $_s17_vv"
    else
        assert_fail "[#1838/SPEC-17] manifest valid_verdicts includes $_s17_vv" \
            "$_s17_vv not listed under valid_verdicts in $_IMPACT_MF"
    fi
done

_test_cleanup_hook() { cleanup_test_env; }
print_test_results
exit $((FAIL > 0))
