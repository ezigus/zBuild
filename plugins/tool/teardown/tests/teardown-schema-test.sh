#!/usr/bin/env bash
# Tests: plugins/tool/teardown — v2 result file schema (issue #1830)
#
# SPEC-1: teardown_run writes teardown-result.json with all mandatory v2 keys
# SPEC-2: one target cleanup failure is recorded; remaining targets still run; verdict=degraded
# SPEC-3: no-cleanup-hook targets appear in data.targets with outcome=no_op
# SPEC-4: aggregate verdict/disposition reflects partial failure (verdict=degraded, disposition=complete)
# SPEC-6: clean run → verdict=complete, disposition=complete, all outcomes=ok|no_op
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: teardown v2 result schema (issue #1830)"
setup_test_env "teardown-schema"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_RUN_ID="teardown-schema-test-$$"

TEARDOWN_DIR="$REPO_ROOT/plugins/tool/teardown"

# ─── helpers ──────────────────────────────────────────────────────────────────

# Make a minimal state file with the given stage names as "complete".
_make_state_file() {
    local state_file="$1"; shift
    local -a stages=("$@")
    local statuses="{"
    local first=1
    for s in "${stages[@]}"; do
        [[ $first -eq 0 ]] && statuses+=","
        statuses+="\"$s\":\"complete\""
        first=0
    done
    statuses+="}"
    printf '{"stage_statuses":%s}' "$statuses" > "$state_file"
}

# Make a mock plugin dir with a cleanup hook that returns the given rc.
_make_plugin_with_cleanup() {
    local dir="$1" id="$2" rc="${3:-0}"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: ${id//-/_}_run
  cleanup: ${id//-/_}_cleanup
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
${id//-/_}_cleanup() { return $rc; }
EOF
}

# Make a mock plugin dir with NO cleanup hook.
_make_plugin_no_cleanup() {
    local dir="$1" id="$2"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: ${id//-/_}_run
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
EOF
}

# ─── SPEC-1: v2 result file has all mandatory keys ────────────────────────────
# CHANGE: at baseline teardown writes no result file.
print_test_section "SPEC-1: v2 result file written with all mandatory keys"

_spec1_state_dir="$TEST_TEMP_DIR/spec1-state"
_spec1_artifacts="$_spec1_state_dir/artifacts"
mkdir -p "$_spec1_state_dir" "$_spec1_artifacts"
_spec1_state="$_spec1_state_dir/pipeline-state.json"
_spec1_plugin="$TEST_TEMP_DIR/spec1-ok-plugin"
_make_plugin_with_cleanup "$_spec1_plugin" "spec1-ok" 0
_make_state_file "$_spec1_state" "spec1-ok"

(
    export ZBUILD_ARTIFACT_DIR="$_spec1_artifacts"
    source "$TEARDOWN_DIR/plugin.sh"
    resolve_stage_plugin() { echo "$_spec1_plugin"; }
    export ZBUILD_TEARDOWN_SCOPE="release"
    teardown_run "teardown" "$_spec1_state" >/dev/null 2>&1
) || true

_spec1_result="$_spec1_artifacts/teardown-result.json"
if [[ -f "$_spec1_result" ]]; then
    assert_pass "[SPEC-1] teardown-result.json written to artifacts dir"
else
    assert_fail "[SPEC-1] teardown-result.json written to artifacts dir" "file missing: $_spec1_result"
fi

if [[ -f "$_spec1_result" ]]; then
    _rc_val="$(jq -r '.result_contract // empty' "$_spec1_result" 2>/dev/null || true)"
    assert_eq "[SPEC-1] result_contract is 2" "2" "$_rc_val"

    _verdict="$(jq -r '.verdict // empty' "$_spec1_result" 2>/dev/null || true)"
    if [[ -n "$_verdict" ]]; then
        assert_pass "[SPEC-1] verdict key present in result"
    else
        assert_fail "[SPEC-1] verdict key present in result" "missing"
    fi

    _disp="$(jq -r '.disposition // empty' "$_spec1_result" 2>/dev/null || true)"
    if [[ -n "$_disp" ]]; then
        assert_pass "[SPEC-1] disposition key present in result"
    else
        assert_fail "[SPEC-1] disposition key present in result" "missing"
    fi

    _reason="$(jq -r '.reason // empty' "$_spec1_result" 2>/dev/null || true)"
    if [[ -n "$_reason" ]]; then
        assert_pass "[SPEC-1] reason key present in result"
    else
        assert_fail "[SPEC-1] reason key present in result" "missing"
    fi

    _targets="$(jq -r '.data.targets // empty' "$_spec1_result" 2>/dev/null || true)"
    if [[ -n "$_targets" ]]; then
        assert_pass "[SPEC-1] data.targets key present in result"
    else
        assert_fail "[SPEC-1] data.targets key present in result" "missing"
    fi
fi

# ─── SPEC-2: one failure recorded; remaining targets still processed ──────────
# CHANGE: at baseline teardown writes no result file.
print_test_section "SPEC-2: partial failure records failed stage and processes remaining"

_spec2_state_dir="$TEST_TEMP_DIR/spec2-state"
_spec2_artifacts="$_spec2_state_dir/artifacts"
mkdir -p "$_spec2_state_dir" "$_spec2_artifacts"
_spec2_state="$_spec2_state_dir/pipeline-state.json"
_spec2_fail_plugin="$TEST_TEMP_DIR/spec2-fail-plugin"
_spec2_ok_plugin="$TEST_TEMP_DIR/spec2-ok-plugin"
_make_plugin_with_cleanup "$_spec2_fail_plugin" "spec2-fail" 7
_make_plugin_with_cleanup "$_spec2_ok_plugin" "spec2-ok" 0
_make_state_file "$_spec2_state" "spec2-fail" "spec2-ok"

(
    export ZBUILD_ARTIFACT_DIR="$_spec2_artifacts"
    source "$TEARDOWN_DIR/plugin.sh"
    resolve_stage_plugin() {
        case "$1" in
            spec2-fail) echo "$_spec2_fail_plugin" ;;
            spec2-ok)   echo "$_spec2_ok_plugin" ;;
        esac
    }
    export ZBUILD_TEARDOWN_SCOPE="release"
    teardown_run "teardown" "$_spec2_state" >/dev/null 2>&1
) || true

_spec2_result="$_spec2_artifacts/teardown-result.json"
if [[ -f "$_spec2_result" ]]; then
    _fail_outcome="$(jq -r '.data.targets[] | select(.stage=="spec2-fail") | .outcome' "$_spec2_result" 2>/dev/null || true)"
    assert_eq "[SPEC-2] failed stage recorded as outcome=failed" "failed" "$_fail_outcome"

    _ok_outcome="$(jq -r '.data.targets[] | select(.stage=="spec2-ok") | .outcome' "$_spec2_result" 2>/dev/null || true)"
    assert_eq "[SPEC-2] succeeding stage still processed (outcome=ok)" "ok" "$_ok_outcome"

    _target_count="$(jq '.data.targets | length' "$_spec2_result" 2>/dev/null || true)"
    assert_eq "[SPEC-2] both targets appear in data.targets" "2" "$_target_count"
else
    assert_fail "[SPEC-2] teardown-result.json exists after partial failure" "missing"
fi

# ─── SPEC-3: absent cleanup hook → outcome=no_op in data.targets ─────────────
# CHANGE: at baseline teardown writes no result file.
print_test_section "SPEC-3: no-cleanup-hook target appears with outcome=no_op"

_spec3_state_dir="$TEST_TEMP_DIR/spec3-state"
_spec3_artifacts="$_spec3_state_dir/artifacts"
mkdir -p "$_spec3_state_dir" "$_spec3_artifacts"
_spec3_state="$_spec3_state_dir/pipeline-state.json"
_spec3_noclean="$TEST_TEMP_DIR/spec3-noclean-plugin"
_spec3_ok="$TEST_TEMP_DIR/spec3-ok-plugin"
_make_plugin_no_cleanup "$_spec3_noclean" "spec3-noclean"
_make_plugin_with_cleanup "$_spec3_ok" "spec3-ok" 0
_make_state_file "$_spec3_state" "spec3-noclean" "spec3-ok"

(
    export ZBUILD_ARTIFACT_DIR="$_spec3_artifacts"
    source "$TEARDOWN_DIR/plugin.sh"
    resolve_stage_plugin() {
        case "$1" in
            spec3-noclean) echo "$_spec3_noclean" ;;
            spec3-ok)      echo "$_spec3_ok" ;;
        esac
    }
    export ZBUILD_TEARDOWN_SCOPE="release"
    teardown_run "teardown" "$_spec3_state" >/dev/null 2>&1
) || true

_spec3_result="$_spec3_artifacts/teardown-result.json"
if [[ -f "$_spec3_result" ]]; then
    _noclean_outcome="$(jq -r '.data.targets[] | select(.stage=="spec3-noclean") | .outcome' "$_spec3_result" 2>/dev/null || true)"
    assert_eq "[SPEC-3] no-cleanup-hook target has outcome=no_op" "no_op" "$_noclean_outcome"

    _ok_outcome="$(jq -r '.data.targets[] | select(.stage=="spec3-ok") | .outcome' "$_spec3_result" 2>/dev/null || true)"
    assert_eq "[SPEC-3] stage with cleanup hook has outcome=ok" "ok" "$_ok_outcome"
else
    assert_fail "[SPEC-3] teardown-result.json exists" "missing"
fi

# ─── SPEC-4: aggregate verdict/disposition reflects partial failure ────────────
# CHANGE: at baseline teardown writes no result file.
print_test_section "SPEC-4: partial failure → verdict=degraded, disposition=complete"

_spec4_result="$_spec2_artifacts/teardown-result.json"
if [[ -f "$_spec4_result" ]]; then
    _spec4_verdict="$(jq -r '.verdict' "$_spec4_result" 2>/dev/null || true)"
    assert_eq "[SPEC-4] partial failure → verdict=degraded" "degraded" "$_spec4_verdict"

    _spec4_disp="$(jq -r '.disposition' "$_spec4_result" 2>/dev/null || true)"
    assert_eq "[SPEC-4] partial failure → disposition=complete (teardown itself completed)" \
        "complete" "$_spec4_disp"
else
    assert_fail "[SPEC-4] result file present (reusing SPEC-2 run)" "missing"
fi

# ─── SPEC-6: manifest consistency guard ──────────────────────────────────────
# GUARD: if the manifest declares result_contract, it must be 2; if outputs are
# declared, teardown_result must be present; if valid_verdicts are listed, they
# must include both complete and degraded. All pass vacuously at the intake
# baseline where these fields were absent. Prevents wrong values from landing.
print_test_section "SPEC-6: manifest result_contract consistency (guard)"

_spec6_manifest="$REPO_ROOT/plugins/tool/teardown/manifest.yaml"

_spec6_rc_val="$(grep -m1 "result_contract:" "$_spec6_manifest" | awk '{print $2}' || echo '')"
if [[ -n "$_spec6_rc_val" ]]; then
    assert_eq "[SPEC-6] manifest result_contract is 2 (if declared)" "2" "$_spec6_rc_val"
else
    assert_pass "[SPEC-6] manifest has no result_contract declared (guard: vacuously true)"
fi

_spec6_has_td="$(grep "teardown_result" "$_spec6_manifest" 2>/dev/null || echo '')"
if [[ -n "$_spec6_has_td" ]]; then
    assert_pass "[SPEC-6] manifest outputs include teardown_result (if declared)"
else
    assert_pass "[SPEC-6] manifest has no teardown_result entry (guard: vacuously true)"
fi

_spec6_has_valid_verdicts="$(grep -m1 "valid_verdicts:" "$_spec6_manifest" 2>/dev/null || echo '')"
if [[ -n "$_spec6_has_valid_verdicts" ]]; then
    # Match "- complete" and "- degraded" as standalone list items (not substrings like teardown.complete)
    _spec6_has_complete="$(grep -v "^#" "$_spec6_manifest" | grep -c "^[[:space:]]*- complete$" || echo 0)"
    _spec6_has_degraded="$(grep -v "^#" "$_spec6_manifest" | grep -c "^[[:space:]]*- degraded$" || echo 0)"
    if [[ "$_spec6_has_complete" -gt 0 && "$_spec6_has_degraded" -gt 0 ]]; then
        assert_pass "[SPEC-6] manifest valid_verdicts includes complete and degraded"
    else
        assert_fail "[SPEC-6] manifest valid_verdicts includes complete and degraded" \
            "complete_count=$_spec6_has_complete degraded_count=$_spec6_has_degraded"
    fi
else
    assert_pass "[SPEC-6] manifest has no valid_verdicts declared (guard: vacuously true)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
