#!/usr/bin/env bash
# Integration test: plan stage end-to-end with a stubbed `claude` binary on PATH.
# Exercises route_to_model -> _route_call_claude across the subprocess boundary
# (real subshell, real exec) and verifies the scope post-validation contract
# from ADR-018 Pattern 1 (#468).
# shellcheck disable=SC2034  # PLAN_GOAL / CANNED_PLAN are read by plan-integration-lib.sh's _run_plan and model mock
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — integration (real claude stub, subprocess boundary)"

setup_test_env "plugin-plan-integration"

# shellcheck source=plan-integration-lib.sh
source "$SCRIPT_DIR/plan-integration-lib.sh"

# ─── Variant 1: in-scope plan → plan.json written, no violations ─────────────
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$CANNED_RESPONSE_FILE"

set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "variant 1: in-scope plan returns rc=0" "0" "$rc"
assert_file_exists "variant 1: plan.json written" "$ARTIFACTS_DIR/plan.json"
v1_violations="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "variant 1: no violation events" "0" "$v1_violations"

# ─── Variant 2: out-of-scope plan → plan.json still written, violation emitted ─
: > "$ZBUILD_EVENTS_JSONL"
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["legacy/oops.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$CANNED_RESPONSE_FILE"

set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "variant 2: out-of-scope returns rc=0 (fail-soft)" "0" "$rc"
assert_file_exists "variant 2: plan.json still written" "$ARTIFACTS_DIR/plan.json"
v2_violations="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "variant 2: one violation event" "1" "$v2_violations"
v2_path="$(jq -r 'select(.type=="plan.scope.violation") | .data.path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "variant 2: violation path is offender" "legacy/oops.sh" "$v2_path"

# ─── Variant 3 (#478): prose-prefixed JSON survives the subprocess boundary ─
# The mock claude returns prose preface + JSON inside the envelope .result.
# The framework parser (_llm_envelope_parse --schema-gate, #944) must slice the
# JSON out before jq -e validation; otherwise the dogfood failure reproduces.
: > "$ZBUILD_EVENTS_JSONL"
printf 'Now I have a complete picture.\n\n%s\n' \
    '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' \
    > "$CANNED_RESPONSE_FILE"

set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "variant 3 (#478): prose-prefixed envelope returns rc=0" "0" "$rc"
assert_file_exists "variant 3 (#478): plan.json written despite prose preface" \
    "$ARTIFACTS_DIR/plan.json"
v3_schema="$(jq -r '.schema_version // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "variant 3 (#478): plan.json parsed via parser-side helper" "1" "$v3_schema"
v3_violations="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "variant 3 (#478): no scope violations on in-scope payload" "0" "$v3_violations"

# ─── Variant 4 (#483): producer-side OUTPUT banner renders markdown ──────────
# When plan opts into ZBUILD_ROUTER_ARTIFACT_ID=plan, the router appends
# metadata.artifact=plan to capture_stage_io. The stage-io output branch now
# dispatches render_plan_md, so plan's own banner shows "# Plan: ..." instead
# of raw JSON.
: > "$ZBUILD_EVENTS_JSONL"
printf '%s\n' '{"schema_version":1,"title":"Banner Title","goal":"render output banner","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$CANNED_RESPONSE_FILE"

# Enable stage-io capture for the "plan" stage with stdout destination.
# The template-loader exports _TPL_STAGE_IO_DESTS_<safe_id> when a template
# is loaded; we set it directly here to bypass needing a full template load.
export ZBUILD_CURRENT_STAGE=plan
export _TPL_STAGE_IO_DESTS_plan="stdout"
# Capture the stage-io banner: open fd 3 to a file.
BANNER_OUT="$TEST_TEMP_DIR/banner-v4.txt"
: > "$BANNER_OUT"
exec 3>"$BANNER_OUT"
export ZBUILD_STAGE_IO_FD=3

set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_plan

assert_eq "variant 4 (#483): plan_run still rc=0 with banner capture on" "0" "$rc"
banner_content="$(cat "$BANNER_OUT" 2>/dev/null || true)"
if grep -qF "# Plan: Banner Title" <<< "$banner_content"; then
    assert_pass "variant 4 (#483): OUTPUT banner contains rendered markdown heading"
else
    assert_fail "variant 4 (#483): OUTPUT banner missing markdown heading" \
        "got: $(printf '%s' "$banner_content" | head -40)"
fi
# The output banner section must not contain the raw JSON title key.
banner_output_section="$(printf '%s' "$banner_content" | sed -n '/── output ──/,/── end stage-io/p')"
if grep -qF '"title":"Banner Title"' <<< "$banner_output_section"; then
    assert_fail "variant 4 (#483): raw JSON leaked into output section" \
        "got: $(printf '%s' "$banner_output_section" | head -20)"
else
    assert_pass "variant 4 (#483): raw JSON absent from output section"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  Issue #1052 — plan-stage resilience integration SPEC tests (RED until Wave B)
#  These cross the real subprocess boundary via the error mock claude on PATH.
#  route.sh persists the failed envelope to
#    ${ZBUILD_ARTIFACT_DIR:-$ZBUILD_STATE_DIR/artifacts}/stage-io/<stage>-sync-error.raw-claude-output.json
#  so the plan plugin must recover from that sidecar. We point the artifact dir
#  at the test state dir and set ZBUILD_CURRENT_STAGE=plan so the sidecar base
#  name is plan-sync-error.
# ═══════════════════════════════════════════════════════════════════════════
print_test_header "Issue #1052 — plan resilience (subprocess boundary, error mock)"

_plan_error_boundary_env


# ─── [#1835/SPEC-3][change] max_turns → rc=1, disposition=out_of_turns ────────
# After v2 migration, a max_turns exhaustion must write plan.json with
# result_contract:2 / verdict=error / disposition=out_of_turns and return rc=1.
# plan.scope_too_large must still fire.  rc=10 is gone.
# The result is intentionally not a valid plan so recovery does not succeed.
print_test_section "[#1835/SPEC-3] max_turns → rc=1, disposition=out_of_turns (v2 migration)"
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_PLAN_RESUME=0
_S3V2_RESULT="$TEST_TEMP_DIR/s3v2-result.txt"
printf '%s' "turn budget exhausted, not a valid plan" > "$_S3V2_RESULT"
_install_plan_error_mock_file --subtype "error_max_turns" --result-file "$_S3V2_RESULT" --rc 1
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
_s3v2_rc=$?
set -e
assert_eq "[#1835/SPEC-3] max_turns plan_run returns rc=1 (not rc=10 after v2 migration)" "1" "$_s3v2_rc"
assert_event_emitted "[#1835/SPEC-3] plan.scope_too_large still fired" \
    "$ZBUILD_EVENTS_JSONL" "plan.scope_too_large"
assert_file_exists "[#1835/SPEC-3] plan.json written on scope_too_large (v2)" \
    "$ARTIFACTS_DIR/plan.json"
assert_eq "[#1835/SPEC-3] plan.json result_contract=2 on scope_too_large" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-3] plan.json verdict=error on scope_too_large" "error" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-3] plan.json disposition=out_of_turns" "out_of_turns" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
unset ZBUILD_PLAN_RESUME 2>/dev/null || true

# ─── [SPEC-3][guard] non-max_turns crash stays claude_cli_failed ─────────────
# A genuine CLI crash (different subtype) must NOT become rc=10 and must NOT emit
# plan.scope_too_large — it stays on the existing claude_cli_failed path.
print_test_section "[SPEC-3][guard] non-max_turns crash stays claude_cli_failed"
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
# Disable resume so a stale scope_too_large cache from the prior SPEC-3 case does
# not splice in (this guard is about the crash discriminator, not resume).
export ZBUILD_PLAN_RESUME=0
_S3G_RESULT="$TEST_TEMP_DIR/s3g-result.txt"
printf '%s' "crashed partway, not a turn-budget exhaustion" > "$_S3G_RESULT"
_install_plan_error_mock_file --subtype "error_during_execution" --result-file "$_S3G_RESULT" --rc 1
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 10 ]]; then
    assert_fail "[SPEC-3][guard] non-max_turns crash must NOT return rc=10" "got rc=$rc"
else
    assert_pass "[SPEC-3][guard] non-max_turns crash does not return rc=10 (rc=$rc)"
fi
_s3g_count="$(jq -r 'select(.type=="plan.scope_too_large") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-3][guard] no plan.scope_too_large on non-max_turns crash" "0" "$_s3g_count"
unset ZBUILD_PLAN_RESUME 2>/dev/null || true

# ─── [SPEC-1][change] partial reasoning captured from sidecar ────────────────
# The partial reasoning carried in the failed envelope's .result must surface in
# plan-context.md after crossing the subprocess boundary.
print_test_section "[SPEC-1][change] partial reasoning from sidecar in plan-context.md"
rm -f "$ARTIFACTS_DIR/plan-context.md" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_PLAN_RESUME=0
_S1_RESULT="$TEST_TEMP_DIR/s1-result.txt"
printf '%s' "SIDECAR_PARTIAL_REASONING_SENTINEL: explored core/router and plugins/agent/plan" > "$_S1_RESULT"
_install_plan_error_mock_file --subtype "error_max_turns" --result-file "$_S1_RESULT" --rc 1
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
set -e
assert_file_exists "[SPEC-1] plan-context.md written on scope_too_large" \
    "$ARTIFACTS_DIR/plan-context.md"
_s1_md="$(cat "$ARTIFACTS_DIR/plan-context.md" 2>/dev/null || true)"
assert_contains "[SPEC-1] plan-context.md carries partial reasoning from sidecar" \
    "$_s1_md" "SIDECAR_PARTIAL_REASONING_SENTINEL"
unset ZBUILD_PLAN_RESUME 2>/dev/null || true

# ─── [SPEC-4][change] max_turns envelope whose .result is a valid plan ────────
# Even on a max_turns exit, if the envelope's .result is a schema-valid plan it
# must be recovered: status=complete, rc=0, plan.envelope.recovered emitted, and
# a real plan.json written.
print_test_section "[SPEC-4][change] recover a valid plan from a max_turns envelope"
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_PLAN_RESUME=0
_S4_RESULT="$TEST_TEMP_DIR/s4-result.txt"
printf '%s' '{"schema_version":1,"title":"recovered-from-envelope","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$_S4_RESULT"
_install_plan_error_mock_file --subtype "error_max_turns" --result-file "$_S4_RESULT" --rc 1
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-4] recovered valid plan → rc=0" "0" "$rc"
assert_event_emitted "[SPEC-4] plan.envelope.recovered emitted" \
    "$ZBUILD_EVENTS_JSONL" "plan.envelope.recovered"
assert_file_exists "[SPEC-4] plan.json written from recovered envelope" \
    "$ARTIFACTS_DIR/plan.json"
_s4_title="$(jq -r '.title // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[SPEC-4] plan.json is the recovered plan" "recovered-from-envelope" "$_s4_title"
_s4_status="$(jq -r '.status // empty' "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true)"
assert_eq "[SPEC-4] plan-context status=complete after recovery" "complete" "$_s4_status"
unset ZBUILD_PLAN_RESUME 2>/dev/null || true

# ─── [SPEC-2][change] dogfood: run1 (error) → run2 (success) resumes ──────────
# Run 1 with the error mock writes exhausted context to the goal-hash cache.
# Run 2 with a success mock (prompt recorded) must resume — the recorded prompt
# carries the prior exploration and plan.context.resumed fires.
print_test_section "[SPEC-2][change] dogfood resume across two runs"
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
PLAN_GOAL="dogfood resume goal across two runs"
export ZBUILD_PLAN_RESUME=1
export ZBUILD_ISSUE_NUMBER="$_ZB_ID"
# Run 1: error mock with a distinctive partial reasoning sentinel (file channel,
# scrub-safe). This must produce a scope_too_large context the second run resumes.
_R1_RESULT="$TEST_TEMP_DIR/dogfood-run1-result.txt"
printf '%s' "DOGFOOD_RUN1_EXPLORATION: mapped the router and plan plugin" > "$_R1_RESULT"
_install_plan_error_mock_file --subtype "error_max_turns" --result-file "$_R1_RESULT" --rc 1
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
set -e
# Run 2: success mock that records the prompt it received.
: > "$ZBUILD_EVENTS_JSONL"
_RUN2_PROMPT="$TEST_TEMP_DIR/run2-prompt.txt"
: > "$_RUN2_PROMPT"
_RUN2_PLAN="$TEST_TEMP_DIR/run2-canned.json"
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$_RUN2_PLAN"
install_envelope_mock_claude --record-prompt "$_RUN2_PROMPT" --file "$_RUN2_PLAN"
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-2] dogfood run 2 returns rc=0" "0" "$rc"
_run2_prompt_body="$(cat "$_RUN2_PROMPT" 2>/dev/null || true)"
assert_contains "[SPEC-2] run 2 prompt carries run-1 exploration sentinel" \
    "$_run2_prompt_body" "DOGFOOD_RUN1_EXPLORATION"
assert_contains "[SPEC-2] run 2 prompt carries PRIOR EXPLORATION CONTEXT heading" \
    "$_run2_prompt_body" "PRIOR EXPLORATION CONTEXT"
assert_event_emitted "[SPEC-2] plan.context.resumed fired on run 2" \
    "$ZBUILD_EVENTS_JSONL" "plan.context.resumed"

# ─── [SPEC-2][guard] resumed context redacted in the real-router prompt ───────
# When the cached reasoning carries an out-of-scope token, the resumed splice
# must pass through apply_scope_redaction so the recorded prompt has it redacted.
print_test_section "[SPEC-2][guard] resumed context redacted before the prompt"
rm -f "$ARTIFACTS_DIR/plan.json" "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
PLAN_GOAL="redaction guard resume goal"
export ZBUILD_PLAN_RESUME=1
# Run 1: error mock whose partial reasoning references an out-of-scope PATH. The
# scope-manifest allows only core/ and plugins/, so legacy/ is out of scope.
# apply_scope_redaction wraps out-of-scope PATHS in <out-of-scope-context> tags
# (the resume splice keeps those tags — it does NOT run _zbuild_sanitize_for_llm,
# which would strip them; see plugin.sh) — so the out-of-scope token must live
# INSIDE a path to be wrapped (a bare free-floating token is not a path and is
# not what scope redaction targets). File channel (scrub-safe) so it reaches the
# sidecar.
_GUARD_RESULT="$TEST_TEMP_DIR/guard-run1-result.txt"
printf '%s' "explored the file legacy/frozen/OUT_OF_SCOPE_SECRET.sh while planning" > "$_GUARD_RESULT"
_install_plan_error_mock_file --subtype "error_max_turns" --result-file "$_GUARD_RESULT" --rc 1
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
set -e
# Run 2: success mock that records the prompt. The redaction chokepoint must
# scrub the out-of-scope token from the spliced prior context.
: > "$ZBUILD_EVENTS_JSONL"
_GUARD_PROMPT="$TEST_TEMP_DIR/guard-prompt.txt"
: > "$_GUARD_PROMPT"
install_envelope_mock_claude --record-prompt "$_GUARD_PROMPT" --file "$_RUN2_PLAN"
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
set -e
_guard_prompt_body="$(cat "$_GUARD_PROMPT" 2>/dev/null || true)"
# apply_scope_redaction WRAPS out-of-scope content in <out-of-scope-context>
# markers (it marks, it does not delete). The load-bearing guarantee is that
# the resumed splice went THROUGH the redaction chokepoint — proven by the
# out-of-scope token appearing ONLY inside that wrapper, and NEVER bare. A bare
# (unwrapped) occurrence would mean the resumed cache bypassed redaction.
if grep -qF "OUT_OF_SCOPE_SECRET" <<<"$_guard_prompt_body"; then
    # Token present → it MUST be inside an <out-of-scope-context> wrapper, and
    # there must be no bare occurrence outside a wrapper.
    _bare="$(printf '%s' "$_guard_prompt_body" \
        | sed -E 's#<out-of-scope-context>[^<]*</out-of-scope-context>##g')"
    if grep -qF "OUT_OF_SCOPE_SECRET" <<<"$_bare"; then
        assert_fail "[SPEC-2][guard] out-of-scope token leaked UNWRAPPED — resumed splice bypassed redaction" \
            "bare context: $(printf '%s' "$_bare" | grep -F OUT_OF_SCOPE_SECRET | head -1)"
    else
        assert_pass "[SPEC-2][guard] out-of-scope token present ONLY inside redaction wrapper (resumed splice was redacted)"
    fi
else
    assert_pass "[SPEC-2][guard] out-of-scope token absent from resumed prompt (redacted)"
fi
unset ZBUILD_PLAN_RESUME ZBUILD_ISSUE_NUMBER 2>/dev/null || true


cleanup_test_env
print_test_results
exit $((FAIL > 0))
