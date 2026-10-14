#!/usr/bin/env bash
# tests/unit/result-outcome-test.sh — one outcome field from one closed list the
# engine enforces (#2366, ADR-054 §6).
#
# Why: every stage should give the engine the same interface. A result carried
# two words — a verdict from about 30 per-stage words, and a disposition — and
# most verdict words only repeated the disposition. Result contract 3 carries
# one: `outcome`.
#
#   O1 [change] the closed list: pass, fail, and the ways a stage can fail to
#               finish; nothing else
#   O2 [change] stage_result_write writes a contract-3 result and refuses a
#               word off the list
#   O3 [change] the engine reads a contract-3 pass and fail: the stage finished
#   O4 [change] a contract-3 outcome that is not pass or fail is how the stage
#               ended — the engine retries or halts on it as before
#   O5 [change] an outcome off the list, a missing outcome, or a missing reason
#               is a broken result
#   O6 [change] a contract-3 outcome needs no per-stage verdict list
#   O7 [change] readers that open results directly see the outcome: open items
#               and a member's terminal failure
#   O8 [retired] contract 2 is gone (contract2-retired-test V2)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "one outcome field from one closed list (#2366)"
setup_test_env "result-outcome"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh" 2>/dev/null || true

S="$TEST_TEMP_DIR/state"; A="$S/artifacts"; P="$TEST_TEMP_DIR/plugins/tool/oc"
mkdir -p "$A" "$P"
cat > "$P/manifest.yaml" <<'MF'
id: oc
name: oc
kind: tool
version: 0.0.1
hooks:
  run: oc_run
outputs:
  - id: oc_result
    path: ${artifact_dir}/oc-result.json
    type: oc-result.json@1
    required: true
    primary: true
config:
  valid_verdicts: [pass]
MF
M="$P/manifest.yaml"; R="$A/oc-result.json"

print_test_section "O1: the closed list"
assert_eq "[O1] the outcome list" \
    "broken fail interrupted misconfigured out_of_turns pass rate_limited throttled timed_out unavailable unusable" \
    "$(outcome_vocabulary 2>/dev/null | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

print_test_section "O2: the shared writer"
stage_result_write "$R" pass "all checks ran" >/dev/null 2>&1; _rc=$?
assert_eq "[O2] writes a pass" "0" "$_rc"
assert_eq "[O2] contract 3" "3" "$(jq -r .result_contract "$R" 2>/dev/null)"
assert_eq "[O2] one outcome field" "pass" "$(jq -r .outcome "$R" 2>/dev/null)"
assert_eq "[O2] no verdict or disposition field" "false" "$(jq 'has("verdict") or has("disposition")' "$R" 2>/dev/null)"
stage_result_write "$R" pass "x" '{"findings":[{"n":1,"text":"t"}]}' >/dev/null 2>&1
assert_eq "[O2] detail goes under data" "t" "$(jq -r '.data.findings[0].text' "$R" 2>/dev/null)"
_rc=0; stage_result_write "$R" degraded "x" >/dev/null 2>&1 || _rc=$?
assert_eq "[O2] a word off the list is refused" "1" "$_rc"

print_test_section "O2b: adding the result to an output that is itself the result"
PJ="$TEST_TEMP_DIR/plan.json"
printf '%s\n' '{"schema_version":1,"steps":[{"id":"step-1","description":"d"}],"result_contract":2,"verdict":"pass","disposition":"complete","reason":"old"}' > "$PJ"
stage_result_add "$PJ" pass "1 work item" >/dev/null 2>&1; _rc=$?
assert_eq "[O2b] adds a pass" "0" "$_rc"
assert_eq "[O2b] contract 3" "3" "$(jq -r .result_contract "$PJ" 2>/dev/null)"
assert_eq "[O2b] the outcome" "pass" "$(jq -r .outcome "$PJ" 2>/dev/null)"
assert_eq "[O2b] the output's own content is kept" "d" "$(jq -r '.steps[0].description' "$PJ" 2>/dev/null)"
assert_eq "[O2b] earlier result fields are gone" "false" "$(jq 'has("verdict") or has("disposition")' "$PJ" 2>/dev/null)"
_before="$(cat "$PJ")"; _rc=0
_err="$(stage_result_add "$PJ" degraded "x" 2>&1 >/dev/null)" || _rc=$?
assert_eq "[O2b] a word off the list is refused" "1" "$_rc"
assert_eq "[O2b] ...and the file is unchanged" "$_before" "$(cat "$PJ")"
printf '[1,2]\n' > "$PJ"; _rc=0
_err="$(stage_result_add "$PJ" pass "x" 2>&1 >/dev/null)" || _rc=$?
assert_eq "[O2b] an output that is not an object is refused" "1" "$_rc"
assert_contains "[O2b] ...saying why" "$_err" "not a JSON object"

print_test_section "O3: pass and fail mean the stage finished"
stage_result_write "$R" pass "ok" >/dev/null 2>&1
assert_eq "[O3] pass reads as pass" "pass" "$(runner_read_stage_verdict "$S" "$M" oc 0 2>/dev/null)"
assert_eq "[O3] pass: the stage finished" "complete" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"
stage_result_write "$R" fail "two tests fail" >/dev/null 2>&1
assert_eq "[O3] fail reads as fail" "fail" "$(runner_read_stage_verdict "$S" "$M" oc 0 2>/dev/null)"
assert_eq "[O3] fail: the stage finished" "complete" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"
assert_eq "[O3] the raw word the cycle tests" "fail" "$(runner_read_stage_verdict_raw "$S" "$M" oc 0 2>/dev/null)"

print_test_section "O4: any other outcome is how the stage ended"
stage_result_write "$R" timed_out "the model call timed out" >/dev/null 2>&1
assert_eq "[O4] timed_out is the disposition" "timed_out" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"
assert_eq "[O4] ...and not a pass" "error" "$(runner_read_stage_verdict "$S" "$M" oc 0 2>/dev/null)"
stage_result_write "$R" misconfigured "no model tier" >/dev/null 2>&1
assert_eq "[O4] misconfigured is the disposition" "misconfigured" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"
assert_eq "[O4] ...and not a pass" "error" "$(runner_read_stage_verdict "$S" "$M" oc 0 2>/dev/null)"

print_test_section "O5: a result the engine cannot read"
printf '{"result_contract":3,"outcome":"degraded","reason":"x"}\n' > "$R"
assert_eq "[O5] a word off the list is broken" "broken" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"
assert_eq "[O5] ...and an error" "error" "$(runner_read_stage_verdict "$S" "$M" oc 0 2>/dev/null)"
printf '{"result_contract":3,"reason":"x"}\n' > "$R"
assert_eq "[O5] no outcome is broken" "broken" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"
printf '{"result_contract":3,"outcome":"pass"}\n' > "$R"
assert_eq "[O5] no reason is broken" "broken" "$(runner_read_stage_disposition "$S" "$M" oc 0 2>/dev/null)"

print_test_section "O6: no per-stage verdict list"
# The manifest above declares only [pass]; a contract-3 fail is still read.
stage_result_write "$R" fail "x" >/dev/null 2>&1
assert_eq "[O6] fail is read though the manifest lists only pass" "fail" "$(runner_read_stage_verdict "$S" "$M" oc 0 2>/dev/null)"

print_test_section "O7: readers that open results directly"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"
O="$TEST_TEMP_DIR/open"; mkdir -p "$O/artifacts"
stage_result_write "$O/artifacts/lint-result.json" fail "lint found 2 errors" >/dev/null 2>&1
stage_result_write "$O/artifacts/doc-result.json" pass "ok" >/dev/null 2>&1
_oi="$(open_items_json "$O")"
assert_eq "[O7] a failed outcome is an open item" "lint" "$(jq -r '.[].opener' <<< "$_oi" 2>/dev/null)"

# O8 retired: contract 2 is no longer read — contract2-retired-test V2.

print_test_section "O9: Previous work reads a contract-3 result"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
W="$TEST_TEMP_DIR/pw"; mkdir -p "$W/artifacts/attempts/oc/iter-0-attempt-1"
stage_result_write "$W/artifacts/attempts/oc/iter-0-attempt-1/oc-result.json" pass "the good one" >/dev/null 2>&1
stage_result_write "$W/artifacts/oc-result.json" timed_out "the model call timed out" >/dev/null 2>&1
printf '{"stage_statuses":{"oc":"failed"},"stage_verdicts":{}}\n' > "$W/pipeline-state.json"
_pw="$( _TPL_STAGES=(oc); _stage_block_previous_work later "$W" "$TEST_TEMP_DIR/plugins" \
        "$(_inputs_resolve_stage later "$TEST_TEMP_DIR/plugins" "$W")" "$W" 2>/dev/null )"
assert_contains "[O9] the stage's outcome is shown" "$_pw" "(verdict: timed_out)"
assert_contains "[O9] a timed-out attempt shows the last good output" "$_pw" "iter-0-attempt-1/oc-result.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
