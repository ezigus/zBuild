#!/usr/bin/env bash
# Tests: plugins/agent/plan — contract v2 result on every path (#1835)
# Split from plan-test.sh (1,399 lines; review #2237). Shared setup: plan-test-lib.sh.
# shellcheck disable=SC2034  # PLAN_GOAL / CANNED_PLAN are read by plan-test-lib.sh's _run_plan and model mock
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — contract v2 result on every path (#1835)"

setup_test_env "plugin-plan-v2-result"

# shellcheck source=plan-test-lib.sh
source "$SCRIPT_DIR/plan-test-lib.sh"

# ═══════════════════════════════════════════════════════════════════════════
#  Issue #1835 — plan plugin contract v2 migration SPEC tests
# ═══════════════════════════════════════════════════════════════════════════
print_test_header "Issue #1835 — plan plugin contract v2 migration"

_MANIFEST_FILE="$PLUGIN_DIR/manifest.yaml"

# Restore canonical state for #1835 tests.
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'
PLAN_GOAL="test goal"
unset ZBUILD_PLAN_RESUME ZBUILD_ISSUE_NUMBER ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR 2>/dev/null || true

# Fresh state dir for v2-specific runs so earlier tests' plan.json writes don't
# blur the assertions.
_V2_STATE="$TEST_TEMP_DIR/state-v2-1835"
_V2_STATE_FILE="$_V2_STATE/pipeline-state.json"
_V2_ARTIFACTS="$_V2_STATE/artifacts"
mkdir -p "$_V2_ARTIFACTS"
printf '{"schema_version":1,"run_id":"test","issue":"%s","stage_statuses":{}}\n' "$_ZB_ID" > "$_V2_STATE_FILE"
cat > "$_V2_STATE/scope-manifest.md" <<'_SCOPE_V2'
+ core/
+ plugins/
_SCOPE_V2

# ─── [#1835/SPEC-7][guard] success path still writes plan.json with original fields ─
# Proves v2 migration does not remove schema_version, steps[], or scope_files.
print_test_section "[#1835/SPEC-7] plan.json original fields survive v2 migration (guard)"
: > "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true
: > "$_CAPTURED_PROMPT_FILE"
set +e
_run_plan "$_V2_STATE_FILE" >/dev/null 2>&1
_s17_rc=$?
set -e
assert_eq "[#1835/SPEC-7] plan_run rc=0 on success" "0" "$_s17_rc"
assert_file_exists "[#1835/SPEC-7] plan.json still created on success" "$_V2_ARTIFACTS/plan.json"
_s7_json="$(cat "$_V2_ARTIFACTS/plan.json" 2>/dev/null || echo '{}')"
_s7_sv="$(printf '%s' "$_s7_json" | jq -r '.schema_version // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-7] plan.json schema_version=1 unchanged (guard)" "1" "$_s7_sv"
_s7_steps="$(printf '%s' "$_s7_json" | jq '.steps | length' 2>/dev/null || echo 0)"
assert_gt "[#1835/SPEC-7] plan.json steps[] non-empty (guard)" "$_s7_steps" "0"
_s7_sf_len="$(printf '%s' "$_s7_json" | jq '.scope_files | length' 2>/dev/null || echo 0)"
assert_gt "[#1835/SPEC-7] plan.json scope_files non-empty (guard)" "$_s7_sf_len" "0"
# Content preserved: scope_files[] must contain the step's file path verbatim.
# The pre-migration plugin already produced scope_files; the migration must not
# strip or transform it. Fails if the migrated plugin omits the value.
_s7_sf_first="$(printf '%s' "$_s7_json" | jq -r '.scope_files[0] // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-7] plan.json scope_files[0] preserves step file value (guard)" \
    "core/foo.sh" "$_s7_sf_first"
# Content preserved: field values from the canned fixture must appear verbatim,
# not just be present. Fails if the migration strips or transforms the plan data.
_s7_step_id="$(printf '%s' "$_s7_json" | jq -r '.steps[0].id // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-7] plan.json steps[0].id matches fixture value (guard)" \
    "step-1" "$_s7_step_id"
_s7_step_desc="$(printf '%s' "$_s7_json" | jq -r '.steps[0].description // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-7] plan.json steps[0].description matches fixture value (guard)" \
    "do thing" "$_s7_step_desc"

# ─── [#1835/SPEC-1][change] success path writes v2 result fields ─────────────
# plan.json on the success path must carry result_contract:2, verdict=pass,
# disposition=complete, and a non-empty reason. Fails at baseline because the
# current plugin writes only plan data without v2 result fields.
print_test_section "[#1835/SPEC-1] success path writes v2 result fields into plan.json"
_s1_rc2="$(printf '%s' "$_s7_json" | jq -r '.result_contract // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-1] plan.json result_contract=2 on success" "2" "$_s1_rc2"
_s1_verdict="$(printf '%s' "$_s7_json" | jq -r '.verdict // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-1] plan.json verdict=pass on success" "pass" "$_s1_verdict"
_s1_disp="$(printf '%s' "$_s7_json" | jq -r '.disposition // empty' 2>/dev/null || true)"
assert_eq "[#1835/SPEC-1] plan.json disposition=complete on success" "complete" "$_s1_disp"
_s1_reason="$(printf '%s' "$_s7_json" | jq -r '.reason // empty' 2>/dev/null || true)"
if [[ -n "$_s1_reason" ]]; then
    assert_pass "[#1835/SPEC-1] plan.json reason is non-empty on success"
else
    assert_fail "[#1835/SPEC-1] plan.json reason is non-empty on success"
fi
# Read half: _verdict_read_result must surface disposition=complete from plan.json primary.
# Fails at merge-base because plan.json has no result_contract or disposition fields there.
# shellcheck source=../../../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh" 2>/dev/null || true
if declare -F _verdict_read_result >/dev/null 2>&1; then
    # Before the change the reader rejects plan.json (rc≠0): that is this
    # assertion FAILING, not a reason to stop the file — under `set -e` a bare
    # call exited here and every later SPEC went unmeasured at the merge-base.
    _s1r_disp=""
    _verdict_read_result "$_V2_STATE" "$PLUGIN_DIR/manifest.yaml" "plan" "0" _s1r || true
    assert_eq "[#1835/SPEC-1] _verdict_read_result surfaces disposition=complete from plan.json primary" \
        "complete" "${_s1r_disp:-}"
else
    assert_fail "[#1835/SPEC-1] _verdict_read_result not available — verdict.sh not sourced"
fi

# ─── [#1835/SPEC-2][change] error path writes plan.json with v2 fields ───────
# On schema_violation / empty_result_envelope / invalid_plan_response, plan.json
# must be written with result_contract:2, verdict=error, disposition=unusable, rc=1.
# Fails at baseline because the error path does not write plan.json at all.
print_test_section "[#1835/SPEC-2] error path writes plan.json with v2 fields (disposition=unusable)"

_S2_STATE="$TEST_TEMP_DIR/state-spec2-1835"
_S2_STATE_FILE="$_S2_STATE/pipeline-state.json"
_S2_ARTIFACTS="$_S2_STATE/artifacts"
mkdir -p "$_S2_ARTIFACTS"
printf '{"schema_version":1,"run_id":"test","issue":"%s","stage_statuses":{}}\n' "$_ZB_ID" > "$_S2_STATE_FILE"
cat > "$_S2_STATE/scope-manifest.md" <<'_S2SCOPE'
+ core/
+ plugins/
_S2SCOPE

# schema_violation: files[] contains a non-string
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":[123],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
rm -f "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e
_run_plan "$_S2_STATE_FILE" >/dev/null 2>&1
_s2a_rc=$?
set -e
assert_eq "[#1835/SPEC-2] schema_violation rc=1" "1" "$_s2a_rc"
assert_file_exists "[#1835/SPEC-2] schema_violation writes plan.json with v2 fields" "$_S2_ARTIFACTS/plan.json"
assert_eq "[#1835/SPEC-2] schema_violation plan.json result_contract=2" "2" \
    "$(jq -r '.result_contract // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-2] schema_violation plan.json verdict=error" "error" \
    "$(jq -r '.verdict // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-2] schema_violation plan.json disposition=unusable" "unusable" \
    "$(jq -r '.disposition // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"

# empty_result_envelope: router rc=0 but empty response
CANNED_PLAN=''
rm -f "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e
_run_plan "$_S2_STATE_FILE" >/dev/null 2>&1
_s2b_rc=$?
set -e
assert_eq "[#1835/SPEC-2] empty_result_envelope rc=1" "1" "$_s2b_rc"
assert_file_exists "[#1835/SPEC-2] empty_result_envelope writes plan.json" "$_S2_ARTIFACTS/plan.json"
assert_eq "[#1835/SPEC-2] empty_result_envelope result_contract=2" "2" \
    "$(jq -r '.result_contract // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-2] empty_result_envelope verdict=error" "error" \
    "$(jq -r '.verdict // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-2] empty_result_envelope disposition=unusable" "unusable" \
    "$(jq -r '.disposition // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"

# invalid_plan_response: the model ANSWERED (router rc=0) with content that is
# not a plan — the output cannot be used. A failed router CALL is not this case:
# the issue names model-call failures by router_reason_disposition, not by the
# plugin (asserted below).
_ORIG_RTM_SPEC2="$(declare -f route_to_model)"
route_to_model() { printf '%s' 'this is not a plan at all'; return 0; }
rm -f "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e
_run_plan "$_S2_STATE_FILE" >/dev/null 2>&1
_s2c_rc=$?
set -e
unset -f route_to_model
if [[ -n "$_ORIG_RTM_SPEC2" ]]; then eval "$_ORIG_RTM_SPEC2"; fi
assert_eq "[#1835/SPEC-2] invalid_plan_response rc=1" "1" "$_s2c_rc"
assert_file_exists "[#1835/SPEC-2] invalid_plan_response writes plan.json" "$_S2_ARTIFACTS/plan.json"
assert_eq "[#1835/SPEC-2] invalid_plan_response result_contract=2" "2" \
    "$(jq -r '.result_contract // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-2] invalid_plan_response verdict=error" "error" \
    "$(jq -r '.verdict // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-2] invalid_plan_response disposition=unusable" "unusable" \
    "$(jq -r '.disposition // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"

# A failed router call (generic rc=1) is a model-call failure: its word comes
# from the shared mapping, never a plugin's own choice (#1835 issue text;
# #2225 "chosen once, not per plugin").
# shellcheck source=../../../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"
_s2_rc1_v=""; _s2_rc1_r=""
_router_rc_classify 1 _s2_rc1_v _s2_rc1_r
_s2_rc1_expect="$(router_reason_disposition "$_s2_rc1_r")"
route_to_model() { printf '%s' '{"error":"router failure"}'; return 1; }
rm -f "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true
set +e
_run_plan "$_S2_STATE_FILE" >/dev/null 2>&1
set -e
unset -f route_to_model
if [[ -n "$_ORIG_RTM_SPEC2" ]]; then eval "$_ORIG_RTM_SPEC2"; fi
assert_eq "[#1835/SPEC-8] a failed router call (rc=1) takes the shared mapping's word ($_s2_rc1_expect)" \
    "$_s2_rc1_expect" "$(jq -r '.disposition // empty' "$_S2_ARTIFACTS/plan.json" 2>/dev/null || true)"


# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
