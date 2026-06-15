#!/usr/bin/env bash
# Tests: plugins/agent/test_assessment plugin (#567)
#
# Pattern 1 LLM-interprets-test-results stage. Mocks route_to_model + redaction;
# asserts schema, verdict invariant, dual-path artifact write, env save/restore,
# event emission.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: test_assessment (#567)"
setup_test_env "plugin-test-assessment"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/test_assessment"

# ─── Fixture state dir ────────────────────────────────────────────────────────
# #824: also initialize a git fixture inside TEST_TEMP_DIR so the plugin can
# read intake-baseline-ref.txt and run `git diff <baseline_sha>` for the
# cumulative numstat. Without this, the plugin fails-closed with rc=2 +
# test_assessment.missing_baseline event.
GIT_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" init --quiet >/dev/null 2>&1
git -C "$GIT_FIXTURE" config user.email 'test@example.com' >/dev/null
git -C "$GIT_FIXTURE" config user.name  'test' >/dev/null
printf 'seed\n' > "$GIT_FIXTURE/SEED"
git -C "$GIT_FIXTURE" add SEED >/dev/null
git -C "$GIT_FIXTURE" commit -m 'baseline' --quiet >/dev/null
_BASELINE_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
cd "$GIT_FIXTURE"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"567","stage_statuses":{}}' > "$STATE_FILE"
printf '%s\n' "$_BASELINE_SHA" > "$STATE_DIR/intake-baseline-ref.txt"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# Seed input artifacts the stage reads.
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":5,"failed":3,"test_output":"FAIL AuthTest: expected 200 got 401","diff_applied":true,"test_cmd":"npm test"}
TR
cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"add auth","goal":"add login","steps":[{"id":"step-1","description":"add login","files":["src/auth.js"],"estimated_lines":20}],"estimated_total_lines":20,"notes":""}
PJ
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mocks ───────────────────────────────────────────────────────────────────
_REDACT_CALLED_FILE="$TEST_TEMP_DIR/redact-called"
apply_scope_redaction() {
    local _input="$1" _output="$2"
    printf '%s' "$3,$5" > "$_REDACT_CALLED_FILE"
    cat "$_input" > "$_output"
    return 0
}

_CAPTURED_PROMPT="$TEST_TEMP_DIR/captured-prompt.txt"
_CAPTURED_ENV_JSON="$TEST_TEMP_DIR/captured-env-json.txt"
_CAPTURED_ARTIFACT_ID="$TEST_TEMP_DIR/captured-artifact-id.txt"
_CAPTURED_TIER="$TEST_TEMP_DIR/captured-tier.txt"
: > "$_CAPTURED_PROMPT"
: > "$_CAPTURED_ENV_JSON"
: > "$_CAPTURED_ARTIFACT_ID"
: > "$_CAPTURED_TIER"

# CANNED_RESPONSE drives the mock; tests reassign it between cases.
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"3 failing","diagnosis":"401 expected 200","required_changes":["fix auth header"],"agrees_with_build_complete":false,"branch_numstat":"files=1 add=10 del=2","failure_summary_md":"## Failures\n- AuthTest","iter":1}'

route_to_model() {
    printf '%s' "${1:-}" > "$_CAPTURED_TIER"
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT"
    printf '%s' "${ZBUILD_ROUTER_JSON_OUTPUT:-unset}" > "$_CAPTURED_ENV_JSON"
    printf '%s' "${ZBUILD_ROUTER_ARTIFACT_ID:-unset}" > "$_CAPTURED_ARTIFACT_ID"
    printf '%s\n' "$CANNED_RESPONSE"
    return 0
}

# ─── Test 1: init ────────────────────────────────────────────────────────────
test_assessment_init >/dev/null 2>&1 || true
assert_eq "T1 init sets ZBUILD_PLUGIN" "test_assessment" "${ZBUILD_PLUGIN:-}"
assert_eq "T1 init sets ZBUILD_PLUGIN_KIND" "agent" "${ZBUILD_PLUGIN_KIND:-}"

# ─── Test 2: happy path — fail verdict (LLM disagrees with build pass) ───────
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2 run returns rc=0" "0" "$rc"
assert_file_exists "T2 test-assessment.json created (flat path)" "$ARTIFACTS_DIR/test-assessment.json"
assert_file_exists "T2 test-assessment.md created (flat path)" "$ARTIFACTS_DIR/test-assessment.md"

# ─── Test 3: schema is valid ─────────────────────────────────────────────────
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
sv="$(printf '%s' "$content" | jq -r '.schema_version' 2>/dev/null)"
assert_eq "T3 schema_version=1" "1" "$sv"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T3 verdict=fail" "fail" "$v"
assert_contains "T3 failure_summary_md present" "$content" "AuthTest"

# ─── Test 4: tier T2 + envelope flags ─────────────────────────────────────────
assert_eq "T4 tier sent = T2" "T2" "$(cat "$_CAPTURED_TIER")"
assert_eq "T4 ZBUILD_ROUTER_JSON_OUTPUT=1 around router" "1" "$(cat "$_CAPTURED_ENV_JSON")"
assert_eq "T4 ZBUILD_ROUTER_ARTIFACT_ID=test_assessment" \
    "test_assessment" "$(cat "$_CAPTURED_ARTIFACT_ID")"

# ─── Test 5: env restored after route_to_model ───────────────────────────────
if [[ -z "${ZBUILD_ROUTER_JSON_OUTPUT:-}" ]]; then
    assert_pass "T5 ZBUILD_ROUTER_JSON_OUTPUT unset after run"
else
    assert_fail "T5 ZBUILD_ROUTER_JSON_OUTPUT unset after run" "still set: $ZBUILD_ROUTER_JSON_OUTPUT"
fi

# ─── Test 6: redaction was called ────────────────────────────────────────────
if [[ -s "$_REDACT_CALLED_FILE" ]]; then
    assert_pass "T6 apply_scope_redaction invoked"
else
    assert_fail "T6 apply_scope_redaction invoked" "no record"
fi

# ─── Test 7: prompt mentions key sections ────────────────────────────────────
prompt="$(cat "$_CAPTURED_PROMPT")"
assert_contains "T7 prompt mentions verdict enum" "$prompt" "verdict"
assert_contains "T7 prompt mentions agrees_with_build_complete" "$prompt" "agrees_with_build_complete"
assert_contains "T7 prompt mentions failure_summary_md" "$prompt" "failure_summary_md"
assert_contains "T7 prompt declares EXACTLY ONE JSON object (ADR-028)" "$prompt" "EXACTLY ONE JSON object"
assert_contains "T7 prompt embeds test_output" "$prompt" "AuthTest"
assert_contains "T7 prompt embeds build verdict" "$prompt" "complete"

# ─── Test 8: invariant downgrade — LLM says pass but test.failed > 0 ─────────
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"looks ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":1}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T8 downgrade run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T8 verdict downgraded to inconclusive" "inconclusive" "$v"
note_present="$(printf '%s' "$content" | jq -r '.required_changes | map(select(. | test("downgrade"))) | length' 2>/dev/null)"
if [[ "$note_present" -ge 1 ]] 2>/dev/null; then
    assert_pass "T8 downgrade note added to required_changes"
else
    assert_fail "T8 downgrade note added to required_changes" "no note"
fi

# ─── Test 9: cycle-iter writes BOTH paths ────────────────────────────────────
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
export ZBUILD_CYCLE_ID="bt"
export ZBUILD_CYCLE_ITER="2"
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"x","diagnosis":"","required_changes":[],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"X.","iter":2}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T9 cycle-iter run rc=0" "0" "$rc"
assert_file_exists "T9 flat path written" "$ARTIFACTS_DIR/test-assessment.json"
assert_file_exists "T9 iter-scoped json written" "$STATE_DIR/cycle-bt/iter-2/test-assessment.json"
assert_file_exists "T9 iter-scoped md written" "$STATE_DIR/cycle-bt/iter-2/test-assessment.md"
unset ZBUILD_CYCLE_ID ZBUILD_CYCLE_ITER

# ─── Test 10: empty router response → error event, no artifact ───────────────
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
CANNED_RESPONSE=""
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "T10 empty response → rc!=0"
else
    assert_fail "T10 empty response → rc!=0" "rc=0 unexpected"
fi
assert_file_not_exists "T10 no artifact on empty response" "$ARTIFACTS_DIR/test-assessment.json"

# ─── Test 11: malformed JSON response → error event, no artifact ────────────
CANNED_RESPONSE="this is not json at all"
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "T11 malformed response → rc!=0"
else
    assert_fail "T11 malformed response → rc!=0" "rc=0 unexpected"
fi
assert_file_not_exists "T11 no artifact on malformed response" "$ARTIFACTS_DIR/test-assessment.json"

# ─── Test 12: dirty-worktree + verdict=fail in test-results → inconclusive ───
# Regression for #847: LLM says pass with agrees=true, build says pass, but
# test-results.json has verdict=fail and failed=0 (stale/missing count shape)
# AND the worktree is dirty (uncommitted file = transient scope-violation edit).
# The stage must downgrade to inconclusive with reason=worktree_not_durable.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR12'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":5,"failed":0,"test_output":"tests exited non-zero but count not captured","diff_applied":true,"test_cmd":"npm test"}
TR12
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS12'
{"schema_version":1,"verdict":"pass","iterations":2,"terminated_reason":"complete"}
BS12
# Add an uncommitted file to make git status --porcelain non-empty (dirty worktree).
printf 'scope-violation edit\n' > "$GIT_FIXTURE/dirty-file.txt"
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"looks ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":2}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T12 dirty+verdict=fail run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T12 verdict downgraded to inconclusive (not pass)" "inconclusive" "$v"
note_present="$(printf '%s' "$content" | jq -r '.required_changes | map(select(. | test("durable|dirty"))) | length' 2>/dev/null)"
if [[ "$note_present" -ge 1 ]] 2>/dev/null; then
    assert_pass "T12 downgrade note mentions dirty/durable in required_changes"
else
    assert_fail "T12 downgrade note mentions dirty/durable in required_changes" "no note"
fi
# Clean up dirty file so it doesn't affect other tests.
rm -f "$GIT_FIXTURE/dirty-file.txt"

# ─── Test 13: empty_diff build + green suite → CONVERGES (verdict=pass) ───────
# Regression for #895 (build_test_cycle livelock). build emits verdict=empty_diff
# (done_sentinel, 0 files changed = work already implemented). With tests green
# and the LLM agreeing the build is complete, the cycle MUST converge:
# test_assessment returns pass, NOT inconclusive. On the pre-fix code, line 406
# rejected any build_verdict != pass, downgrading to inconclusive and livelocking
# the cycle to max_iterations.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR13'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TR13
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS13'
{"schema_version":1,"verdict":"empty_diff","iterations":1,"terminated_reason":"done_sentinel"}
BS13
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"all green, nothing to change","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":1}'
_dg_before="$(grep -c 'test_assessment.downgrade' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"; _dg_before="${_dg_before:-0}"
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T13 empty_diff+green run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T13 empty_diff + green converges (verdict=pass, not inconclusive)" "pass" "$v"
_dg_after="$(grep -c 'test_assessment.downgrade' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"; _dg_after="${_dg_after:-0}"
if [[ "$_dg_after" -eq "$_dg_before" ]]; then
    assert_pass "T13 no test_assessment.downgrade event on converge"
else
    assert_fail "T13 no test_assessment.downgrade event on converge" "downgrade emitted ($_dg_before -> $_dg_after)"
fi

# ─── Test 14: empty_diff + DIRTY worktree → inconclusive (not durable) ────────
# #895 durability guard: an empty_diff build that left an uncommitted worktree
# is suspect (build claimed no changes yet files are on disk). Must NOT converge
# even with green tests — the on-disk state is transient.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
printf 'uncommitted\n' > "$GIT_FIXTURE/dirty-file.txt"
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T14 empty_diff+dirty run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T14 empty_diff + dirty worktree → inconclusive" "inconclusive" "$v"
rm -f "$GIT_FIXTURE/dirty-file.txt"

# ─── Test 15: empty_diff + test_verdict=fail → inconclusive ──────────────────
# Even on empty_diff, a non-pass test_verdict must block convergence (line 404).
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR15'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":378,"failed":1,"test_output":"1 file failures","diff_applied":true,"test_cmd":"npm test"}
TR15
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T15 empty_diff + test fail → inconclusive" "inconclusive" "$v"

# ─── Test 16: scope_violation + green suite → inconclusive (allowlist guard) ──
# The converge allowlist is exactly {pass, empty_diff}. scope_violation must
# STILL downgrade even when tests pass (transient out-of-scope edits being
# reverted) — the fix must not widen the allowlist beyond empty_diff.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR16'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TR16
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS16'
{"schema_version":1,"verdict":"scope_violation","iterations":1,"terminated_reason":"scope_violation"}
BS16
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T16 scope_violation + green stays inconclusive" "inconclusive" "$v"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
