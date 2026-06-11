#!/usr/bin/env bash
# Integration test (#781): impact plugin's deterministic prefilter surfaces
# numeric-literal + golden-snapshot scope gaps that the LLM symbol tracer
# alone would miss.
#
# Scope: drive impact plugin end-to-end with a mocked claude CLI that emits
# a clean JSON envelope with missing=[]. Without the #781 fix, that empty
# missing[] would propagate as verdict=complete. WITH the fix, the post-LLM
# bash-merge enforces the shape-change-golden floor and forces verdict=
# incomplete with the missing golden files in missing[].
#
# Pinned assertions:
#   I1: shape-change plan + LLM emits empty missing[] → impact.json.verdict=incomplete
#   I2: impact.json.missing[] contains both event-sequence.golden paths
#   I3: non-shape plan + LLM emits empty missing[] → impact.json.verdict=complete (no false forcing)
#   I4: prompt sent to LLM contains the CANDIDATE GAPS sentinel for shape-change plans
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact prefilter regression #781 — golden floor + numeric grep"
setup_test_env "impact-prefilter-781"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/impact"

# State + artifact scaffolding.
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"

# Synthetic scope manifest required by redaction chokepoint.
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ config/
+ core/
+ plugins/
+ tests/
SCOPE

# Source plugin (loads helpers + bootstrap + prefilter lib + mocks).
# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# Mocks: apply_scope_redaction copies through, route_to_model echoes canned.
apply_scope_redaction() {
    local _input="$1" _output="$2"
    cat "$_input" > "$_output"
    return 0
}

_CAPTURED_IMPACT_PROMPT_FILE="$TEST_TEMP_DIR/captured-impact-prompt.txt"
: > "$_CAPTURED_IMPACT_PROMPT_FILE"
CANNED_IMPACT_RESPONSE='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}'
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_IMPACT_PROMPT_FILE"
    printf '%s\n' "$CANNED_IMPACT_RESPONSE"
    return 0
}

# Use the REAL repo root so the prefilter scans the real
# config/templates/standard.yaml + tests/golden/**.
export ZBUILD_REPO_ROOT="$REPO_ROOT"

# ─── I1+I2: shape-change plan with empty LLM missing[] ──────────────────────
# Plan touches standard.yaml → prefilter detects shape change → forces
# event-sequence goldens into missing[] even though LLM returned empty.
cat > "$ARTIFACTS_DIR/plan.json" <<'PLAN'
{"schema_version":1,"title":"shape change","goal":"g","steps":[{"id":"step-1","description":"touch flow","files":["config/templates/standard.yaml"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
PLAN

: > "$_CAPTURED_IMPACT_PROMPT_FILE"
STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '%s' '{"schema_version":1,"run_id":"t","issue":"781","stage_statuses":{}}' > "$STATE_FILE"

set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "I1: impact_run rc=0 with shape-change plan" "0" "$rc"

assert_file_exists "I1: impact.json written" "$ARTIFACTS_DIR/impact.json"
verdict="$(jq -r '.verdict' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I1: verdict forced to incomplete (golden floor)" "incomplete" "$verdict"

# I2: both event-sequence goldens present in missing[].files_to_add.
missing_files_csv="$(jq -r '[.missing[]?.files_to_add[]?] | join(",")' "$ARTIFACTS_DIR/impact.json")"
case "$missing_files_csv" in
    *"full-pipeline/event-sequence.golden"*)
        assert_pass "I2: full-pipeline event-sequence.golden in missing[]" ;;
    *)
        assert_fail "I2: full-pipeline golden missing: $missing_files_csv" ;;
esac
case "$missing_files_csv" in
    *"parity/event-sequence.golden"*)
        assert_pass "I2: parity event-sequence.golden in missing[]" ;;
    *)
        assert_fail "I2: parity golden missing: $missing_files_csv" ;;
esac

# I2b (#781 contract pinning): forced entry has step_id="prefilter" and
# reason contains "#781" + "shape-change" so downstream consumers can
# distinguish prefilter-floor entries from LLM-emitted gaps.
forced_step_id="$(jq -r '[.missing[] | select(.step_id == "prefilter")] | .[0].step_id // ""' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I2b: forced missing[] entry has step_id=prefilter" "prefilter" "$forced_step_id"
forced_reason="$(jq -r '[.missing[] | select(.step_id == "prefilter")] | .[0].reason // ""' "$ARTIFACTS_DIR/impact.json")"
case "$forced_reason" in
    *"#781"*) assert_pass "I2b: forced entry reason cites #781" ;;
    *) assert_fail "I2b: forced reason missing #781: $forced_reason" ;;
esac
case "$forced_reason" in
    *"shape-change"*) assert_pass "I2b: forced entry reason cites shape-change" ;;
    *) assert_fail "I2b: forced reason missing shape-change: $forced_reason" ;;
esac

# I2c (#781): impact.verdict.incomplete event emitted with missing_count>=1.
events="$(cat "$ZBUILD_EVENTS_JSONL")"
case "$events" in
    *'"type":"impact.verdict.incomplete"'*)
        assert_pass "I2c: impact.verdict.incomplete event emitted" ;;
    *)
        assert_fail "I2c: impact.verdict.incomplete event NOT emitted" ;;
esac

# I4: prompt contains CANDIDATE GAPS sentinel when shape change detected.
captured="$(cat "$_CAPTURED_IMPACT_PROMPT_FILE")"
assert_contains "I4: prompt contains CANDIDATE GAPS sentinel" \
    "$captured" "CANDIDATE GAPS"

# I4b (review fix): CANDIDATE GAPS sentinel appears BEFORE the PLAN: marker,
# not after. Otherwise the LLM parses gaps as part of the plan body.
cand_line="$(printf '%s\n' "$captured" | grep -n 'CANDIDATE GAPS' | head -1 | cut -d: -f1 || true)"
plan_line="$(printf '%s\n' "$captured" | grep -n '^PLAN:$' | head -1 | cut -d: -f1 || true)"
if [[ -n "$cand_line" && -n "$plan_line" && "$cand_line" -lt "$plan_line" ]]; then
    assert_pass "I4b: CANDIDATE GAPS precedes PLAN: marker in prompt"
else
    assert_fail "I4b: ordering broken cand_line=$cand_line plan_line=$plan_line"
fi

# ─── I3: non-shape plan → no forcing, verdict=complete ──────────────────────
cat > "$ARTIFACTS_DIR/plan.json" <<'PLAN'
{"schema_version":1,"title":"non-shape","goal":"g","steps":[{"id":"step-1","description":"touch plugin","files":["plugins/agent/foo/plugin.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
PLAN
: > "$_CAPTURED_IMPACT_PROMPT_FILE"
rm -f "$ARTIFACTS_DIR/impact.json"

set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "I3: impact_run rc=0 with non-shape plan" "0" "$rc"
verdict="$(jq -r '.verdict' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I3: non-shape plan → verdict=complete (no forced golden floor)" "complete" "$verdict"

# CANDIDATE GAPS sentinel must NOT appear for non-shape plans.
captured="$(cat "$_CAPTURED_IMPACT_PROMPT_FILE")"
case "$captured" in
    *"CANDIDATE GAPS"*)
        assert_fail "I3: CANDIDATE GAPS should NOT appear for non-shape plans" ;;
    *)
        assert_pass "I3: prompt omits CANDIDATE GAPS for non-shape plans" ;;
esac

# I3b (review fix): no prefilter-floor reason injected for non-shape plans.
# Pins the contract that the floor only fires under shape-change detection.
nonshape_reasons="$(jq -r '[.missing[]?.reason] | join("|")' "$ARTIFACTS_DIR/impact.json")"
case "$nonshape_reasons" in
    *"prefilter floor"*)
        assert_fail "I3b: non-shape plan must NOT inject prefilter floor reason" ;;
    *)
        assert_pass "I3b: non-shape plan does not inject prefilter floor reason" ;;
esac

# ─── I5 (review fix): partial-merge — LLM returns ONE golden in missing[] ───
# Verifies jq native set-difference adds only the missing other golden, no
# duplicates, and preserves the LLM-provided entry.
cat > "$ARTIFACTS_DIR/plan.json" <<'PLAN'
{"schema_version":1,"title":"shape","goal":"g","steps":[{"id":"step-1","description":"touch flow","files":["config/templates/standard.yaml"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
PLAN
rm -f "$ARTIFACTS_DIR/impact.json"
CANNED_IMPACT_RESPONSE='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"llm-step","files_to_add":["tests/golden/full-pipeline/event-sequence.golden"],"reason":"LLM caught one golden"}],"impact_feedback_md":"partial"}'

set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "I5: impact_run rc=0 partial-merge" "0" "$rc"

# Exactly two distinct golden paths in missing[].files_to_add.
distinct_goldens="$(jq -r '[.missing[]?.files_to_add[]? | select(endswith("event-sequence.golden"))] | unique | length' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I5: exactly 2 distinct goldens (no duplicates)" "2" "$distinct_goldens"

# LLM-provided entry preserved (reason "LLM caught one golden" still present).
llm_reason_preserved="$(jq -r '[.missing[] | select(.reason == "LLM caught one golden")] | length' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I5: LLM-provided missing[] entry preserved" "1" "$llm_reason_preserved"

# Forced prefilter entry adds ONLY the missing golden, not the one LLM already had.
forced_files="$(jq -r '[.missing[] | select(.step_id == "prefilter") | .files_to_add[]?] | sort | join(",")' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I5: forced entry adds only the parity golden (the missing one)" \
    "tests/golden/parity/event-sequence.golden" "$forced_files"

# ─── I6 (review fix): no-op when LLM already covered both goldens ────────────
rm -f "$ARTIFACTS_DIR/impact.json"
CANNED_IMPACT_RESPONSE='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"llm-step","files_to_add":["tests/golden/full-pipeline/event-sequence.golden","tests/golden/parity/event-sequence.golden"],"reason":"LLM caught both"}],"impact_feedback_md":"both"}'

set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "I6: impact_run rc=0 no-op merge" "0" "$rc"
forced_entry_count="$(jq -r '[.missing[] | select(.step_id == "prefilter")] | length' "$ARTIFACTS_DIR/impact.json")"
assert_eq "I6: no forced prefilter entry when LLM covered both" "0" "$forced_entry_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
