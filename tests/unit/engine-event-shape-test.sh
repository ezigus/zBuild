#!/usr/bin/env bash
# Tests: engine event shapes — model.route, model.outcome, event-bus envelope,
# scope-manifest fence (redaction.refused).
# Issue #385: pin JSON shapes as goldens so field-level regressions are caught by CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "engine event shapes (#385) — model.route, model.outcome, bus envelope, scope-manifest fence"

setup_test_env "engine-event-shape"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

# ── Event bus pointing at isolated temp dir ──────────────────────────────────
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# Canonical timestamp used in all goldens — substituted in during normalisation.
CANONICAL_TS="2026-01-01T00:00:00.000Z"

# _normalise_event: read the last line of the JSONL log, replace .ts with the
# canonical timestamp, and return the resulting JSON.  This keeps the golden
# files stable across runs without losing any other field.
_normalise_event() {
    local jsonl_file="$1"
    jq -Sc --arg ts "$CANONICAL_TS" '.ts = $ts' <(tail -1 "$jsonl_file")
}

# ── G1: event-bus envelope shape ────────────────────────────────────────────
# Emit a well-known event with all envelope fields populated via env.
export ZBUILD_RUN_ID="test-run-385"
export ZBUILD_ISSUE="$_ZB_ID"
export ZBUILD_PLUGIN="test-plugin"
export ZBUILD_PLUGIN_KIND="agent"
eb_emit_event "pipeline.start" "stage=intake"
unset ZBUILD_ISSUE ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND

actual="$(_normalise_event "$ZBUILD_EVENTS_JSONL")"

set +e
assert_golden "engine-event-bus-envelope" "$actual"
g1_rc=$?
set -e
if [[ $g1_rc -eq 0 ]]; then
    assert_pass "G1: event-bus envelope shape (ts, run_id, issue, type, plugin, kind, data, schema_version)"
else
    assert_fail "G1: event-bus envelope shape" "assert_golden returned $g1_rc"
fi

# Verify required top-level envelope keys are present in the emitted event.
envelope_keys="$(echo "$actual" | jq -r 'keys | sort | join(",")')"
expected_keys="data,issue,kind,plugin,run_id,schema_version,ts,type"
if [[ "$envelope_keys" == "$expected_keys" ]]; then
    assert_pass "G1b: envelope has exactly the 8 expected top-level keys"
else
    assert_fail "G1b: envelope top-level keys" "expected: $expected_keys, got: $envelope_keys"
fi

# ── G2: model.route shape ────────────────────────────────────────────────────
# Emit model.route directly via eb_emit_event with canonical field values.
unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND
export ZBUILD_RUN_ID="test-run-385"
eb_emit_event "model.route" \
    "tier=T1" \
    "model_id=test-model" \
    "provider=anthropic" \
    "recommended=test-model" \
    "applied=test-model" \
    "selector=candidates[0]" \
    "override_source=candidates[0]" \
    "cost_per_input_mtok=3.0" \
    "cost_per_output_mtok=15.0" \
    "cache_eligible=true"

actual="$(_normalise_event "$ZBUILD_EVENTS_JSONL")"

set +e
assert_golden "engine-event-model-route" "$actual"
g2_rc=$?
set -e
if [[ $g2_rc -eq 0 ]]; then
    assert_pass "G2: model.route event shape matches golden"
else
    assert_fail "G2: model.route event shape" "assert_golden returned $g2_rc"
fi

# Verify data payload keys for model.route.
route_data_keys="$(echo "$actual" | jq -r '.data | keys | sort | join(",")')"
expected_route_keys="applied,cache_eligible,cost_per_input_mtok,cost_per_output_mtok,model_id,override_source,provider,recommended,selector,tier"
if [[ "$route_data_keys" == "$expected_route_keys" ]]; then
    assert_pass "G2b: model.route data has expected payload keys"
else
    assert_fail "G2b: model.route data keys" "expected: $expected_route_keys, got: $route_data_keys"
fi

# Verify event type field.
route_type="$(echo "$actual" | jq -r '.type')"
if [[ "$route_type" == "model.route" ]]; then
    assert_pass "G2c: model.route .type field is correct"
else
    assert_fail "G2c: model.route .type field" "expected: model.route, got: $route_type"
fi

# ── G3: model.outcome shape ──────────────────────────────────────────────────
eb_emit_event "model.outcome" \
    "tier=T1" \
    "model_id=test-model" \
    "cache_eligible=true" \
    "input_tokens=120" \
    "output_tokens=45" \
    "cache_read_input_tokens=0" \
    "cache_creation_input_tokens=0"

actual="$(_normalise_event "$ZBUILD_EVENTS_JSONL")"

set +e
assert_golden "engine-event-model-outcome" "$actual"
g3_rc=$?
set -e
if [[ $g3_rc -eq 0 ]]; then
    assert_pass "G3: model.outcome event shape matches golden"
else
    assert_fail "G3: model.outcome event shape" "assert_golden returned $g3_rc"
fi

# Verify data payload keys for model.outcome.
outcome_data_keys="$(echo "$actual" | jq -r '.data | keys | sort | join(",")')"
expected_outcome_keys="cache_creation_input_tokens,cache_eligible,cache_read_input_tokens,input_tokens,model_id,output_tokens,tier"
if [[ "$outcome_data_keys" == "$expected_outcome_keys" ]]; then
    assert_pass "G3b: model.outcome data has expected payload keys"
else
    assert_fail "G3b: model.outcome data keys" "expected: $expected_outcome_keys, got: $outcome_data_keys"
fi

# ── G4: scope-manifest fence (redaction.refused) shape ──────────────────────
# Emit redaction.refused with canonical values — this is the fail-closed event
# emitted by apply_scope_redaction when the scope manifest is missing/empty.
eb_emit_event "redaction.refused" \
    "reason=missing_scope_manifest" \
    "input=test-input.txt" \
    "cycle=0"

actual="$(_normalise_event "$ZBUILD_EVENTS_JSONL")"

set +e
assert_golden "engine-event-scope-manifest-fence" "$actual"
g4_rc=$?
set -e
if [[ $g4_rc -eq 0 ]]; then
    assert_pass "G4: scope-manifest fence (redaction.refused) event shape matches golden"
else
    assert_fail "G4: scope-manifest fence event shape" "assert_golden returned $g4_rc"
fi

# Verify data payload keys for the fence event.
fence_data_keys="$(echo "$actual" | jq -r '.data | keys | sort | join(",")')"
expected_fence_keys="cycle,input,reason"
if [[ "$fence_data_keys" == "$expected_fence_keys" ]]; then
    assert_pass "G4b: redaction.refused data has expected payload keys (reason, input, cycle)"
else
    assert_fail "G4b: redaction.refused data keys" "expected: $expected_fence_keys, got: $fence_data_keys"
fi

# Verify the reason field value — this is load-bearing for grep-based alerting.
fence_reason="$(echo "$actual" | jq -r '.data.reason')"
if [[ "$fence_reason" == "missing_scope_manifest" ]]; then
    assert_pass "G4c: redaction.refused .data.reason is stable (missing_scope_manifest)"
else
    assert_fail "G4c: redaction.refused reason stability" "expected: missing_scope_manifest, got: $fence_reason"
fi

# ── G5: schema_version invariant ─────────────────────────────────────────────
# All engine events must carry schema_version=1 (ARCHITECTURE.md §6).
all_versions="$(jq -r '.schema_version' "$ZBUILD_EVENTS_JSONL" | sort -u)"
if [[ "$all_versions" == "1" ]]; then
    assert_pass "G5: all emitted events carry schema_version=1"
else
    assert_fail "G5: schema_version invariant" "unexpected values: $all_versions"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
