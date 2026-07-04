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

# ─── Test 6: routes through route_to_model (the redaction chokepoint) ────────
# ADR-043: redaction is owned by route_to_model, so the plugin no longer calls
# apply_scope_redaction directly. Redaction-coverage is proven by the assembled
# prompt being handed to route_to_model, which redacts it by construction.
if [[ -s "$_CAPTURED_PROMPT" ]]; then
    assert_pass "T6 prompt routed through route_to_model (redaction chokepoint)"
else
    assert_fail "T6 prompt routed through route_to_model (redaction chokepoint)" "no prompt captured"
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

# ─── [standard.yaml convergence class — not applicable to simple.yaml (I10-C)] ──
# T13, T13a, T14, T15, T16 verify the pass-invariant coercion that drives
# convergence in standard.yaml's build_test_cycle (empty_diff promotion,
# build-verdict allowlist, dirty-worktree durability guard). In simple.yaml
# (I10-C) test_assessment is absent from the cycle; the gate-aggregator is the sole
# convergence driver; these coercion rules are not applicable there. The [SPEC-3]
# guard below confirms the standard convergence path is unchanged by I10-C.

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
assert_eq "[SPEC-3] T13 empty_diff + green converges (verdict=pass, not inconclusive) — standard.yaml convergence class intact" "pass" "$v"
_dg_after="$(grep -c 'test_assessment.downgrade' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"; _dg_after="${_dg_after:-0}"
if [[ "$_dg_after" -eq "$_dg_before" ]]; then
    assert_pass "T13 no test_assessment.downgrade event on converge"
else
    assert_fail "T13 no test_assessment.downgrade event on converge" "downgrade emitted ($_dg_before -> $_dg_after)"
fi

# ─── Test 13a: empty_diff + LLM agrees=false + green suite → CONVERGES ──────────
# [SPEC-1] Regression for issue #954/#38 iter-2 inner-full-suite-gate plateau:
# build_verdict=empty_diff, test_verdict=pass, test_failed=0, worktree=clean, but
# the LLM returns agrees_with_build_complete=false (it cannot interpret empty_diff
# as "build completed"). The stage MUST converge (verdict=pass), NOT downgrade to
# inconclusive. Objective evidence is conclusive; LLM opinion must not veto it
# for empty_diff. (Change-behavior SPEC — pre-fix baseline returns inconclusive.)
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR13A'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":406,"failed":0,"test_output":"total: 406/406 passed","diff_applied":true,"test_cmd":"npm test"}
TR13A
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS13A'
{"schema_version":1,"verdict":"empty_diff","iterations":1,"terminated_reason":"done_sentinel"}
BS13A
# LLM returns agrees_with_build_complete=false — the exact bug scenario.
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"all green","diagnosis":"","required_changes":[],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":1}'
_dg_before13a="$(grep -c 'test_assessment.downgrade' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"; _dg_before13a="${_dg_before13a:-0}"
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-1] T13a empty_diff+llm-disagrees+green returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "[SPEC-1] T13a empty_diff + agrees=false + green → pass (not inconclusive)" "pass" "$v"
_dg_after13a="$(grep -c 'test_assessment.downgrade' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"; _dg_after13a="${_dg_after13a:-0}"
if [[ "$_dg_after13a" -eq "$_dg_before13a" ]]; then
    assert_pass "[SPEC-1] T13a no test_assessment.downgrade event when empty_diff converges"
else
    assert_fail "[SPEC-1] T13a no test_assessment.downgrade event" "downgrade emitted ($_dg_before13a -> $_dg_after13a)"
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

# ─── Test 17: acceptance block present + testfiles exist + LLM av=true → pass ─
# Happy path: design.md has an acceptance block, named testfile exists, and the
# LLM returns acceptance_verified=true alongside a pass verdict.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR17'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TR17
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS17'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS17
mkdir -p "$GIT_FIXTURE/tests/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GIT_FIXTURE/tests/unit/t17-acceptance-test.sh"
cat > "$ARTIFACTS_DIR/design.md" <<'DM17'
# Design

```acceptance
SPEC: test_assessment verifies acceptance criteria from design.md
SPEC: acceptance_verified=true when all specs are grounded in passing tests
TESTFILES:
tests/unit/t17-acceptance-test.sh
```
DM17
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"all green","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","acceptance_verified":true,"failure_summary_md":"All good.","iter":1}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T17 acceptance+pass returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T17 acceptance_verified=true + pass verdict preserved" "pass" "$v"
rm -f "$ARTIFACTS_DIR/design.md" "$GIT_FIXTURE/tests/unit/t17-acceptance-test.sh"

# ─── Test 18: testfile missing → verdict=fail (pre-LLM) ──────────────────────
# When a TESTFILE named in the acceptance block does not exist, the plugin must
# fail-closed BEFORE calling the LLM (no token spend).
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR18'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TR18
cat > "$ARTIFACTS_DIR/design.md" <<'DM18'
# Design

```acceptance
SPEC: test_assessment fails closed when TESTFILES are absent
TESTFILES:
tests/unit/nonexistent-test-file.sh
```
DM18
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T18 missing testfile returns rc=0" "0" "$rc"
assert_file_exists "T18 test-assessment.json written on pre-LLM fail" "$ARTIFACTS_DIR/test-assessment.json"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T18 missing testfile → verdict=fail" "fail" "$v"
reason="$(printf '%s' "$content" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "T18 reason=acceptance_not_verified" "acceptance_not_verified" "$reason"
rm -f "$ARTIFACTS_DIR/design.md"

# ─── Test 21 (Copilot review): unsafe TESTFILES path → fail-closed ───────────
# A TESTFILES path from the LLM-produced design.md that is absolute or contains
# ".." must be rejected fail-closed (verdict=fail, no LLM call) so the gate can
# never reference a file outside the repo — mirrors the design + build guards.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR21'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TR21
cat > "$ARTIFACTS_DIR/design.md" <<'DM21'
# Design

```acceptance
SPEC: unsafe acceptance testfile paths are rejected
TESTFILES:
../escape-test.sh
/tmp/zbuild-abs-test.sh
```
DM21
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T21 unsafe testfile returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json" 2>/dev/null)"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T21 unsafe testfile path → verdict=fail" "fail" "$v"
reason="$(printf '%s' "$content" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "T21 reason=acceptance_not_verified" "acceptance_not_verified" "$reason"
rm -f "$ARTIFACTS_DIR/design.md"

# ─── Test 19: testfiles present + LLM acceptance_verified=false → fail ───────
# When the LLM returns acceptance_verified=false with a pass verdict, the stage
# must downgrade pass→fail with reason=acceptance_llm_rejected.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR19'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TR19
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS19'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS19
mkdir -p "$GIT_FIXTURE/tests/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GIT_FIXTURE/tests/unit/t19-acceptance-test.sh"
cat > "$ARTIFACTS_DIR/design.md" <<'DM19'
# Design

```acceptance
SPEC: spec that the LLM cannot verify
TESTFILES:
tests/unit/t19-acceptance-test.sh
```
DM19
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"looks ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","acceptance_verified":false,"failure_summary_md":"Spec not grounded.","iter":1}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T19 acceptance_verified=false returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T19 acceptance_verified=false downgrades pass→fail" "fail" "$v"
note_present="$(printf '%s' "$content" | jq -r '.required_changes | map(select(. | test("acceptance"))) | length' 2>/dev/null)"
if [[ "$note_present" -ge 1 ]] 2>/dev/null; then
    assert_pass "T19 downgrade note mentions acceptance in required_changes"
else
    assert_fail "T19 downgrade note mentions acceptance in required_changes" "no note"
fi
rm -f "$ARTIFACTS_DIR/design.md" "$GIT_FIXTURE/tests/unit/t19-acceptance-test.sh"

# ─── Test 20: no design.md → acceptance check skipped, plugin runs normally ──
# When design.md is absent the acceptance path is a no-op: the plugin calls the
# LLM as normal and emits whatever verdict the LLM returns.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md" \
      "$ARTIFACTS_DIR/design.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR20'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":5,"failed":2,"test_output":"2 failing","diff_applied":true,"test_cmd":"npm test"}
TR20
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS20'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS20
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"2 failing","diagnosis":"missing impl","required_changes":["fix it"],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"Tests failed.","iter":1}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T20 no design.md returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T20 no design.md → LLM verdict preserved (fail)" "fail" "$v"

# ─── Test 22: [SPEC-8] router rc!=0 → no test-assessment.json (#1024 AC-1) ────
# CHANGE: before #1024, a router failure in test_assessment fell through to
# verdict parsing with empty raw_response, producing a schema-violation error
# but still potentially writing an error artifact. After #1024 the plugin
# returns non-zero immediately with no artifact written.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR22'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":5,"failed":3,"test_output":"FAIL","diff_applied":true,"test_cmd":"npm test"}
TR22
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS22'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS22

_SPEC8_STATE_DIR="$(mktemp -d)"
export ZBUILD_STATE_DIR="$_SPEC8_STATE_DIR"
export ZBUILD_LLM_FAIL_THRESHOLD=99   # prevent abort so we isolate the no-artifact check

route_to_model() { return 1; }

set +e
_test_assessment_run_inner \
    "$STATE_DIR/scope-manifest.md" \
    "$ARTIFACTS_DIR/test-results.json" \
    "$ARTIFACTS_DIR/plan.json" \
    "$ARTIFACTS_DIR/build-summary.json" \
    "$ARTIFACTS_DIR/test-assessment.json" \
    "$ARTIFACTS_DIR/test-assessment.md" \
    "$ARTIFACTS_DIR" \
    "$STATE_DIR" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "[SPEC-8] router_rc=1 → test_assessment_run_inner returns non-zero"
else
    assert_fail "[SPEC-8] router_rc=1 → expected non-zero rc" "got rc=0"
fi
assert_file_not_exists "[SPEC-8] router_rc=1 → no test-assessment.json written (no coercion)" \
    "$ARTIFACTS_DIR/test-assessment.json"
unset ZBUILD_STATE_DIR ZBUILD_LLM_FAIL_THRESHOLD
rm -rf "$_SPEC8_STATE_DIR"

# Restore the original route_to_model mock so cleanup is clean.
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"restored","diagnosis":"","required_changes":[],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"X.","iter":1}'
route_to_model() {
    printf '%s' "${1:-}" > "$_CAPTURED_TIER"
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT"
    printf '%s' "${ZBUILD_ROUTER_JSON_OUTPUT:-unset}" > "$_CAPTURED_ENV_JSON"
    printf '%s' "${ZBUILD_ROUTER_ARTIFACT_ID:-unset}" > "$_CAPTURED_ARTIFACT_ID"
    printf '%s\n' "$CANNED_RESPONSE"
    return 0
}

# ─── Test ADV-1: [SPEC-1] advisory mode — no pass-invariant downgrade ────────
# CHANGE (I10-C): when ZBUILD_TEST_ASSESSMENT_ADVISORY=1 the plugin must return
# the LLM verdict directly without convergence-class enforcement. Here the LLM
# says pass but test-results.json has verdict=fail and failed=3 — in standard
# mode the pass invariant downgrades to inconclusive. In advisory mode the LLM
# pass must be emitted as-is. This assertion FAILS at baseline (before I10-C)
# because the downgrade still fires, producing inconclusive instead of pass.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TRADV1'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":5,"failed":3,"test_output":"FAIL AuthTest","diff_applied":true,"test_cmd":"npm test"}
TRADV1
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BSADV1'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BSADV1
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"advisory","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"Advisory.","iter":1}'
export ZBUILD_TEST_ASSESSMENT_ADVISORY=1
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-1] T-ADV-1 advisory mode run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "[SPEC-1] T-ADV-1 advisory mode: LLM pass emitted directly (no downgrade to inconclusive)" "pass" "$v"
unset ZBUILD_TEST_ASSESSMENT_ADVISORY

# ─── Test ADV-2: [SPEC-2] advisory mode — scope_violation build does not block ─
# CHANGE (I10-C): in advisory mode the build-verdict convergeable allowlist is
# bypassed. With ZBUILD_TEST_ASSESSMENT_ADVISORY=1, build_verdict=scope_violation
# must not downgrade a LLM pass — the verdict passes through as-is. In standard
# mode scope_violation is not in the allowlist {pass, empty_diff} and would cause
# inconclusive. This assertion FAILS at baseline (before I10-C).
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
cat > "$ARTIFACTS_DIR/test-results.json" <<'TRADV2'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":379,"failed":0,"test_output":"total: 379/379 passed","diff_applied":true,"test_cmd":"npm test"}
TRADV2
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BSADV2'
{"schema_version":1,"verdict":"scope_violation","iterations":1,"terminated_reason":"scope_violation"}
BSADV2
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"advisory scope_violation","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"Advisory.","iter":1}'
export ZBUILD_TEST_ASSESSMENT_ADVISORY=1
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-2] T-ADV-2 advisory mode with scope_violation run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "[SPEC-2] T-ADV-2 advisory mode: scope_violation build does not block LLM pass (convergeable allowlist bypassed)" "pass" "$v"
unset ZBUILD_TEST_ASSESSMENT_ADVISORY

# ─── Test 23: [SPEC-9] postamble recovery via _test_assessment_envelope_schema_ok
# CHANGE: before #944 a brace-bearing postamble caused LAST-wins to select junk
# → schema validation failed → rc=1. After #944 recovery fires and the real
# envelope is used → rc=0 and test-assessment.json has correct verdict.
print_test_section "23. [SPEC-9] postamble recovery — test_assessment selects real envelope"
_SPEC9_DIR="$TEST_TEMP_DIR/spec9"
mkdir -p "$_SPEC9_DIR/artifacts"
export ZBUILD_STATE_DIR="$_SPEC9_DIR"
export ZBUILD_LLM_FAIL_THRESHOLD=99

# Set up fixtures that satisfy pass-invariant: failed=0 + build verdict=pass.
cat > "$_SPEC9_DIR/scope-manifest.md" <<'SCOPE9'
+ core/
SCOPE9
cat > "$_SPEC9_DIR/artifacts/test-results.json" <<'TRSPEC9'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":10,"failed":0,"test_output":"10/10 passed","diff_applied":true,"test_cmd":"npm test"}
TRSPEC9
cat > "$_SPEC9_DIR/artifacts/plan.json" <<'PSPEC9'
{"goal":"test postamble recovery","steps":[],"schema_version":1}
PSPEC9
cat > "$_SPEC9_DIR/artifacts/build-summary.json" <<'BSSPEC9'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"pass"}
BSSPEC9
printf '%s\n' "$_BASELINE_SHA" > "$_SPEC9_DIR/intake-baseline-ref.txt"

# Real envelope first, brace-bearing postamble appended.
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"all green","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":1} Based on analysis: {"note":"postamble-junk"}'

OUTPUT_TA_SPEC9="$_SPEC9_DIR/artifacts/ta-spec9.json"
rm -f "$OUTPUT_TA_SPEC9"
set +e
_test_assessment_run_inner \
    "$_SPEC9_DIR/scope-manifest.md" \
    "$_SPEC9_DIR/artifacts/test-results.json" \
    "$_SPEC9_DIR/artifacts/plan.json" \
    "$_SPEC9_DIR/artifacts/build-summary.json" \
    "$OUTPUT_TA_SPEC9" \
    "$_SPEC9_DIR/artifacts" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-9] postamble recovery → _test_assessment_run_inner returns rc=0" "0" "$rc"
assert_file_exists "[SPEC-9] postamble recovery → test-assessment.json written" "$OUTPUT_TA_SPEC9"
_spec9_verdict="$(jq -r '.verdict // empty' "$OUTPUT_TA_SPEC9" 2>/dev/null || true)"
assert_eq "[SPEC-9] postamble recovery → recovered envelope verdict=pass" \
    "pass" "$_spec9_verdict"
unset ZBUILD_STATE_DIR ZBUILD_LLM_FAIL_THRESHOLD
rm -rf "$_SPEC9_DIR"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
