#!/usr/bin/env bash
# Integration test: test_assessment acceptance-block flow (ADR-031 / issue #843-D)
#
# Covers: design.md acceptance block consumed by test_assessment — happy path
# (acceptance_verified=true → pass preserved), missing-TESTFILE path (pre-LLM
# fail-closed), and acceptance_llm_rejected path (acceptance_verified=false →
# pass downgraded to fail).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test_assessment acceptance-block flow (ADR-031 / #843-D)"
setup_test_env "ta-acceptance-flow"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/test_assessment"

# ─── Git fixture (required for cumulative numstat, #824) ─────────────────────
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

# ─── State dir ───────────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"ta-flow","issue":"867","stage_statuses":{}}' > "$STATE_FILE"
printf '%s\n' "$_BASELINE_SHA" > "$STATE_DIR/intake-baseline-ref.txt"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
+ tests/
SCOPE

# Common passing test-results and build-summary (reused across scenarios)
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":10,"failed":0,"test_output":"10/10 passed","diff_applied":true,"test_cmd":"npm test"}
TR
cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"wire acceptance block","goal":"implement ADR-031","steps":[{"id":"step-1","description":"wire acceptance","files":["plugins/agent/test_assessment/plugin.sh"],"estimated_lines":80}],"estimated_total_lines":80,"notes":""}
PJ
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS

# Create a testfile that will be referenced in the acceptance block (must exist).
mkdir -p "$GIT_FIXTURE/tests/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GIT_FIXTURE/tests/unit/ta-flow-unit-test.sh"

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mocks ───────────────────────────────────────────────────────────────────
apply_scope_redaction() {
    local _input="$1" _output="$2"
    cat "$_input" > "$_output"
    return 0
}

CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"all green","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","acceptance_verified":true,"failure_summary_md":"All good.","iter":1}'

# File-based call counter — bash variables set inside $(...) subshells do not
# propagate to the parent. Writing to a file survives the subshell boundary.
_TA_ROUTE_LOG="$TEST_TEMP_DIR/route-calls.log"
: > "$_TA_ROUTE_LOG"

route_to_model() {
    printf '.\n' >> "$_TA_ROUTE_LOG"
    printf '%s\n' "$CANNED_RESPONSE"
    return 0
}

# Helper: count route_to_model calls since the log was last cleared.
_route_call_count() { wc -l < "$_TA_ROUTE_LOG" | tr -d ' '; }
_route_log_reset()  { : > "$_TA_ROUTE_LOG"; }

# ─── IT-1: design.md with acceptance block + testfile present → pass ─────────
# Full happy path: block present, testfile exists, LLM returns
# acceptance_verified=true, verdict=pass. No downgrade should occur.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
_route_log_reset
cat > "$ARTIFACTS_DIR/design.md" <<'DM1'
# Design

Some prose.

```acceptance
SPEC: test_assessment reads the acceptance block from design.md
SPEC: acceptance_verified=true when specs are grounded in passing test output
TESTFILES:
tests/unit/ta-flow-unit-test.sh
```
DM1
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "IT-1 run returns rc=0" "0" "$rc"
assert_file_exists "IT-1 test-assessment.json written" "$ARTIFACTS_DIR/test-assessment.json"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "IT-1 acceptance happy path → verdict=pass" "pass" "$v"
# jq // treats false as alternative; use explicit comparison for booleans
av="$(printf '%s' "$content" | jq -r 'if .acceptance_verified == true then "true" elif .acceptance_verified == false then "false" else "absent" end' 2>/dev/null)"
assert_eq "IT-1 acceptance_verified=true preserved in output" "true" "$av"
_it1_calls="$(_route_call_count)"
if [[ "$_it1_calls" -ge 1 ]]; then
    assert_pass "IT-1 LLM was called (acceptance block processed normally)"
else
    assert_fail "IT-1 LLM was called" "route_to_model not invoked"
fi

# ─── IT-2: TESTFILES absent → verdict=fail, no LLM call ──────────────────────
# When a file listed under TESTFILES does not exist on disk, the plugin must
# emit verdict=fail with reason=acceptance_not_verified BEFORE calling the LLM.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
_route_log_reset
cat > "$ARTIFACTS_DIR/design.md" <<'DM2'
# Design

```acceptance
SPEC: missing TESTFILE causes pre-LLM fail-closed verdict
TESTFILES:
tests/unit/this-file-does-not-exist.sh
```
DM2
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "IT-2 missing testfile returns rc=0" "0" "$rc"
assert_file_exists "IT-2 test-assessment.json written on pre-LLM fail" "$ARTIFACTS_DIR/test-assessment.json"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "IT-2 missing testfile → verdict=fail" "fail" "$v"
reason="$(printf '%s' "$content" | jq -r '.reason // ""' 2>/dev/null)"
assert_eq "IT-2 reason=acceptance_not_verified" "acceptance_not_verified" "$reason"
assert_eq "IT-2 no LLM call on pre-LLM fail" "0" "$(_route_call_count)"

# ─── IT-3: acceptance_verified=false from LLM → pass downgraded to fail ──────
# When TESTFILES exist but the LLM cannot ground the SPEC claims
# (acceptance_verified=false), a verdict=pass from the LLM is downgraded to fail.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
_route_log_reset
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"looks ok but spec unverifiable","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","acceptance_verified":false,"failure_summary_md":"Spec not grounded.","iter":1}'
cat > "$ARTIFACTS_DIR/design.md" <<'DM3'
# Design

```acceptance
SPEC: a claim the LLM rejects
TESTFILES:
tests/unit/ta-flow-unit-test.sh
```
DM3
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "IT-3 acceptance_llm_rejected returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "IT-3 acceptance_verified=false downgrades pass→fail" "fail" "$v"
# jq // treats false as alternative; use explicit comparison
av="$(printf '%s' "$content" | jq -r 'if .acceptance_verified == false then "false" elif .acceptance_verified == true then "true" else "absent" end' 2>/dev/null)"
assert_eq "IT-3 acceptance_verified=false recorded in output" "false" "$av"
# downgrade note must appear in required_changes
note_cnt="$(printf '%s' "$content" | jq -r '[.required_changes[] | select(test("acceptance"))] | length' 2>/dev/null)"
if [[ "${note_cnt:-0}" -ge 1 ]]; then
    assert_pass "IT-3 downgrade note referencing acceptance in required_changes"
else
    assert_fail "IT-3 downgrade note referencing acceptance in required_changes" "none found"
fi
# downgrade event must have been emitted
if grep -q 'acceptance_llm_rejected' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "IT-3 test_assessment.downgrade event with reason=acceptance_llm_rejected emitted"
else
    assert_fail "IT-3 test_assessment.downgrade event with reason=acceptance_llm_rejected emitted" "not in events.jsonl"
fi

# ─── IT-4: no design.md → acceptance check skipped, LLM verdict used ─────────
# When design.md is absent the acceptance path is a no-op.
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md" \
      "$ARTIFACTS_DIR/design.md"
_route_log_reset
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"2 failing","diagnosis":"x","required_changes":["fix"],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"2 failing.","iter":1}'
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR4'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":8,"failed":2,"test_output":"2 failing","diff_applied":true,"test_cmd":"npm test"}
TR4
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "IT-4 no design.md returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "IT-4 no design.md → LLM verdict used (fail)" "fail" "$v"
assert_eq "IT-4 LLM was called when no design.md" "1" "$(_route_call_count)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
