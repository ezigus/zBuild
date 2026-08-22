#!/usr/bin/env bash
# Tests: plugins/tool/teardown — v2 result file schema (issue #1830)
#
# SPEC-1: teardown_run writes teardown-result.json with all mandatory v2 keys
# SPEC-2: one target cleanup failure is recorded; remaining targets still run; verdict=degraded
# SPEC-3: no-cleanup-hook targets appear in data.targets with outcome=no_op
# SPEC-4: aggregate verdict/disposition reflects partial failure (verdict=degraded, disposition=complete)
# SPEC-6: manifest declares result_contract 2, the teardown_result output, and valid_verdicts
# SPEC-7: an unwritable artifacts dir still yields rc=0 + teardown.complete, and names the loss
#
# SPEC-5 lives in tests/integration/cleanup-release-test.sh — it guards the rc=0
# invariant against a failing cleanup HOOK, where this file's SPEC-7 guards it
# against a failing result WRITE.
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

# rc is captured rather than `|| true`d: SPEC-4 reads this run's artifact, and a
# swallowed failure here would surface there as "file missing" instead of naming
# the real cause.
_spec2_rc=0
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
) || _spec2_rc=$?

assert_eq "[SPEC-2] teardown_run exits 0 despite a failing cleanup hook" "0" "$_spec2_rc"

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

# Reuses SPEC-2's run deliberately — same partial-failure scenario, different
# claim. SPEC-2 above already asserted that run's rc, so a missing file here can
# only mean the write itself failed.
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

# Asserted, not guarded: both branches used to call assert_pass, so this went
# green whether or not the output was declared. The declaration is load-bearing
# — lint-verdict-classify requires config.valid_verdicts of any manifest with a
# `primary: true` output, and #1831 dispatches teardown as an ordinary stage
# whose required output the engine enforces.
_spec6_has_td="$(grep "teardown_result" "$_spec6_manifest" 2>/dev/null || echo '')"
if [[ -n "$_spec6_has_td" ]]; then
    assert_pass "[SPEC-6] manifest outputs declare teardown_result"
else
    assert_fail "[SPEC-6] manifest outputs declare teardown_result" \
        "no teardown_result entry in $_spec6_manifest"
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

# ─── SPEC-7: a failed result write keeps the rc=0 guarantee ──────────────────
# CHANGE: at baseline the write was an unguarded `| atomic_write`, and the loop
# above leaves errexit ON, so a failed write aborted teardown_run before both
# `teardown.complete` and the `return 0` ADR-054 §4 mandates.
#
# errexit has to be LIVE at the call site to observe this: bash suppresses it
# inside a function invoked in a `||`/`if` list, which is why every other SPEC
# here — and the old SPEC-5 in cleanup-release-test.sh — could not have caught
# it. Hence the child `bash -e` that calls teardown_run bare and prints a
# sentinel only if control reaches the next line.
print_test_section "SPEC-7: unwritable artifacts dir → still rc=0, still teardown.complete"

# Inline rather than skip_on_platform/skip_unless_capable: those print results and
# end the FILE, which would mask any later failure (#1748). Only this SPEC is
# unexercisable as root; the rest of the file must still run.
if [[ "$(id -u)" == "0" ]]; then
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: [SPEC-7] running as root; chmod cannot deny writes" >&2
else
    _spec7_dir="$TEST_TEMP_DIR/spec7"
    _spec7_artifacts="$_spec7_dir/artifacts"
    _spec7_plugin="$_spec7_dir/plugin"
    _spec7_events="$_spec7_dir/events.jsonl"
    mkdir -p "$_spec7_dir/state" "$_spec7_artifacts"
    _make_plugin_with_cleanup "$_spec7_plugin" "spec7-ok" 0
    _make_state_file "$_spec7_dir/state/pipeline-state.json" "spec7-ok"
    chmod 555 "$_spec7_artifacts"

    _spec7_out=""
    _spec7_rc=0
    _spec7_out="$(
        ZBUILD_ARTIFACT_DIR="$_spec7_artifacts" \
        ZBUILD_TEARDOWN_SCOPE="release" \
        ZBUILD_EVENTS_JSONL="$_spec7_events" \
        TEARDOWN_DIR="$TEARDOWN_DIR" \
        SPEC7_PLUGIN="$_spec7_plugin" \
        SPEC7_STATE="$_spec7_dir/state/pipeline-state.json" \
        bash -c '
            set -euo pipefail
            source "$TEARDOWN_DIR/plugin.sh"
            resolve_stage_plugin() { echo "$SPEC7_PLUGIN"; }
            teardown_run "teardown" "$SPEC7_STATE" >/dev/null 2>&1
            echo "REACHED_RETURN"
        ' 2>/dev/null
    )" || _spec7_rc=$?

    chmod 755 "$_spec7_artifacts"

    assert_eq "[SPEC-7] teardown_run returns 0 when the result write fails" "0" "$_spec7_rc"
    assert_eq "[SPEC-7] control reaches the end of teardown_run (not aborted by errexit)" \
        "REACHED_RETURN" "$_spec7_out"

    if [[ -f "$_spec7_events" ]] && grep -q '"teardown.result.write_failed"' "$_spec7_events"; then
        assert_pass "[SPEC-7] the lost result is recorded on teardown.result.write_failed"
    else
        assert_fail "[SPEC-7] the lost result is recorded on teardown.result.write_failed" \
            "event absent from $_spec7_events"
    fi

    if [[ -f "$_spec7_events" ]] && grep -q '"teardown.complete"' "$_spec7_events"; then
        assert_pass "[SPEC-7] teardown.complete still emitted after a failed write"
    else
        assert_fail "[SPEC-7] teardown.complete still emitted after a failed write" \
            "event absent from $_spec7_events"
    fi

    # The event is emitted, so it must be declared — #1717 composes the engine's
    # known set from manifests, and an undeclared emit is a schema violation.
    if grep -q "teardown.result.write_failed" "$REPO_ROOT/plugins/tool/teardown/manifest.yaml"; then
        assert_pass "[SPEC-7] teardown.result.write_failed declared in provides.events"
    else
        assert_fail "[SPEC-7] teardown.result.write_failed declared in provides.events" "undeclared"
    fi
fi

# ─── SPEC-5: ZBUILD_CLEAN_DRY_RUN=1 emits would_clean events, skips hooks ────
# CHANGE: at baseline the dry-run path does not exist; ZBUILD_CLEAN_DRY_RUN=1
# has no effect and no teardown.dry_run.would_clean event is ever emitted.
print_test_section "SPEC-5: ZBUILD_CLEAN_DRY_RUN=1 emits would_clean events; no hooks invoked"

_spec5_state_dir="$TEST_TEMP_DIR/spec5-state"
_spec5_artifacts="$_spec5_state_dir/artifacts"
_spec5_events="$TEST_TEMP_DIR/spec5-events.jsonl"
_spec5_sentinel="$TEST_TEMP_DIR/spec5-sentinel"
mkdir -p "$_spec5_state_dir" "$_spec5_artifacts"

_spec5_plugin="$TEST_TEMP_DIR/spec5-plugin"
mkdir -p "$_spec5_plugin"
cat > "$_spec5_plugin/manifest.yaml" <<EOF
id: spec5-hook
name: Spec5 Hook
kind: tool
version: 0.0.1
hooks:
  run: spec5_hook_run
  cleanup: spec5_hook_cleanup
EOF
cat > "$_spec5_plugin/plugin.sh" <<EOF
spec5_hook_run() { return 0; }
spec5_hook_cleanup() { touch '$_spec5_sentinel'; return 0; }
EOF

_make_state_file "$_spec5_state_dir/pipeline-state.json" "spec5-hook"

_spec5_rc=0
(
    export ZBUILD_CLEAN_DRY_RUN=1
    export ZBUILD_TEARDOWN_SCOPE=release
    export ZBUILD_ARTIFACT_DIR="$_spec5_artifacts"
    export ZBUILD_EVENTS_JSONL="$_spec5_events"
    source "$TEARDOWN_DIR/plugin.sh"
    resolve_stage_plugin() { echo "$_spec5_plugin"; }
    teardown_run "teardown" "$_spec5_state_dir/pipeline-state.json" >/dev/null 2>&1
) || _spec5_rc=$?

assert_eq "[SPEC-5] teardown_run exits 0 under ZBUILD_CLEAN_DRY_RUN=1" "0" "$_spec5_rc"

if [[ -f "$_spec5_events" ]] && grep -q '"teardown.dry_run.would_clean"' "$_spec5_events"; then
    assert_pass "[SPEC-5] teardown.dry_run.would_clean event emitted when dry-run=1"
else
    assert_fail "[SPEC-5] teardown.dry_run.would_clean event emitted when dry-run=1" \
        "event absent from $_spec5_events"
fi

if [[ ! -f "$_spec5_sentinel" ]]; then
    assert_pass "[SPEC-5] cleanup hook NOT invoked under dry-run (sentinel absent)"
else
    assert_fail "[SPEC-5] cleanup hook NOT invoked under dry-run (sentinel absent)" \
        "sentinel found: $_spec5_sentinel"
fi

if grep -q "teardown.dry_run.would_clean" "$REPO_ROOT/plugins/tool/teardown/manifest.yaml"; then
    assert_pass "[SPEC-5] teardown.dry_run.would_clean declared in provides.events"
else
    assert_fail "[SPEC-5] teardown.dry_run.would_clean declared in provides.events" \
        "undeclared"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
