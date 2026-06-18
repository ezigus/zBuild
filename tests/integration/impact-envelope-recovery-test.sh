#!/usr/bin/env bash
# Integration test (#908): impact plugin recovers its envelope when the model
# emits a brace-bearing POSTAMBLE after the JSON.
#
# The shared parser extract_json_and_surrounding_prose is LAST-wins (#478) so a
# postamble containing its own {...} is selected over the genuine envelope; the
# schema gate then fails and _impact_run_inner returns 1 -> empty impact
# iteration. WITH the fix, schema-aware recovery re-selects the FIRST schema-
# valid object, emits impact.envelope.recovered, and the run succeeds.
#
# Pinned assertions:
#   R1: brace-bearing postamble -> impact_run rc=0 (recovered, not empty)
#   R2: verdict read from the ENVELOPE, not the postamble object
#   R3: missing[] from the envelope preserved
#   R4: impact.envelope.recovered emitted exactly once
#   R5: #767 stray-prose sidecar still written (postamble preserved, not lost)
#   R6 (control): clean single-envelope response emits NO recovery event
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact envelope recovery #908 — brace-bearing postamble"
setup_test_env "impact-envelope-recovery-it"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/impact"

STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ config/
+ core/
+ plugins/
+ tests/
SCOPE

# Non-shape design scope (no standard.yaml / goldens) so the #781/#881 floor
# stays inert and does NOT mutate the verdict — isolates the recovery behaviour.
cat > "$ARTIFACTS_DIR/design.md" <<'DESIGN'
# Design

```scope
plugins/agent/foo/plugin.sh
```
DESIGN

# Non-shape plan for the same reason.
cat > "$ARTIFACTS_DIR/plan.json" <<'PLAN'
{"schema_version":1,"title":"non-shape","goal":"g","steps":[{"id":"step-1","description":"edit foo","files":["plugins/agent/foo/plugin.sh"],"estimated_lines":3}],"estimated_total_lines":3,"notes":""}
PLAN

# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

apply_scope_redaction() {
    local _input="$1" _output="$2"
    cat "$_input" > "$_output"
    return 0
}

# Router emits the #908 failure shape: a valid envelope FIRST, then a postamble
# carrying its OWN balanced object after a stray ```json fence.
CANNED_IMPACT_RESPONSE='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"verified"}
Based on my comprehensive analysis, here is a summary:
```json
{"summary":"all good"}
```'
route_to_model() {
    printf '%s' "$CANNED_IMPACT_RESPONSE"
    return 0
}

export ZBUILD_REPO_ROOT="$REPO_ROOT"

STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '%s' '{"schema_version":1,"run_id":"t908","issue":"908","stage_statuses":{}}' > "$STATE_FILE"

# ─── R1-R5: brace-bearing postamble recovers ────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "R1: impact_run rc=0 (recovered, not empty iteration)" "0" "$rc"
assert_file_exists "R2: impact.json written via recovery" "$ARTIFACTS_DIR/impact.json"
assert_eq "R2: verdict read from the ENVELOPE not the postamble object" \
    "complete" "$(jq -r '.verdict' "$ARTIFACTS_DIR/impact.json" 2>/dev/null)"
assert_eq "R3: missing[] from the envelope preserved (empty)" \
    "0" "$(jq -r '.missing | length' "$ARTIFACTS_DIR/impact.json" 2>/dev/null)"
recov_count="$(grep -c 'impact.envelope.recovered' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "R4: impact.envelope.recovered emitted exactly once" "1" "$recov_count"
assert_file_exists "R5: #767 stray-prose sidecar still written" "$ARTIFACTS_DIR/impact-stray-prose.txt"

# ─── R6 (control): clean single envelope emits NO recovery event ────────────
CANNED_IMPACT_RESPONSE='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}'
: > "$ZBUILD_EVENTS_JSONL"; rm -f "$ARTIFACTS_DIR/impact.json"
set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "R6: clean single-envelope run rc=0" "0" "$rc"
assert_eq "R6: no recovery event on a clean single-envelope response" "0" \
    "$(grep -c 'impact.envelope.recovered' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
