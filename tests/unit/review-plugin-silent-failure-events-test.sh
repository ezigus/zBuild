#!/usr/bin/env bash
# Unit test (#527): review plugin silent-failure mitigation events.
#
# CRIT #4: review.test_status.missing event MUST fire when test-results.json is
#          absent, regardless of which downstream verdict path is taken.
# CRIT #5: review.jq.parse_error event MUST fire when jq fails to parse
#          test-results.json (malformed JSON), with the parse-error message.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "review plugin silent-failure events (#527)"
setup_test_env "review-silent-failure-527"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# Source the event bus + a stub emit_event delegating to eb_emit_event.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
emit_event() { eb_emit_event "$@"; }
export -f emit_event

# Source the review plugin (only _review_derive_test_status is needed for the
# jq.parse_error test; the missing-event test will source _review_run_inner-adjacent
# code via the plugin file).
# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# ─── Test 1: _review_derive_test_status on malformed JSON → parse_error event ─
: > "$ZBUILD_EVENTS_JSONL"
BAD_JSON="$TEST_TEMP_DIR/bad.json"
printf '{not valid json' > "$BAD_JSON"
out="$(_review_derive_test_status "$BAD_JSON")"
assert_eq "T1: malformed json → derive returns 'unknown'" "unknown" "$out"
if grep -q '"type":"review.jq.parse_error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "T1: review.jq.parse_error event emitted for malformed json"
else
    assert_fail "T1: review.jq.parse_error event" "missing from $ZBUILD_EVENTS_JSONL"
fi

# ─── Test 2: well-formed JSON missing .verdict → derive=unknown, NO parse_error ─
: > "$ZBUILD_EVENTS_JSONL"
NO_VERDICT="$TEST_TEMP_DIR/noverdict.json"
printf '{"passed":1}' > "$NO_VERDICT"
out="$(_review_derive_test_status "$NO_VERDICT")"
assert_eq "T2: missing .verdict → derive returns 'unknown'" "unknown" "$out"
if grep -q '"type":"review.jq.parse_error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "T2: parse_error should NOT fire for well-formed json" "found event"
else
    assert_pass "T2: parse_error NOT emitted for well-formed json without .verdict"
fi

# ─── Test 3: well-formed verdict=pass → derive=passed ─────────────────────────
PASS_JSON="$TEST_TEMP_DIR/pass.json"
printf '{"verdict":"pass"}' > "$PASS_JSON"
out="$(_review_derive_test_status "$PASS_JSON")"
assert_eq "T3: verdict=pass → derive returns 'passed'" "passed" "$out"

# ─── Test 4: missing file → derive=unknown, NO parse_error event ──────────────
: > "$ZBUILD_EVENTS_JSONL"
out="$(_review_derive_test_status "$TEST_TEMP_DIR/does-not-exist.json")"
assert_eq "T4: missing file → derive returns 'unknown'" "unknown" "$out"
if grep -q '"type":"review.jq.parse_error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "T4: parse_error should NOT fire for missing file" "found event"
else
    assert_pass "T4: parse_error NOT emitted for missing file (handled by .missing event in _review_run_inner)"
fi

# ─── Test 5: review.test_status.missing fires when test-results.json absent ───
# Drive _review_run_inner with a missing test-results path. We mock the LLM
# router by overriding route_to_model to write a fixed approve verdict; the
# missing-event MUST fire BEFORE the coercion path runs (so it's emitted
# regardless of verdict).
: > "$ZBUILD_EVENTS_JSONL"
ART_DIR="$TEST_TEMP_DIR/t5-art"; mkdir -p "$ART_DIR"
SCOPE="$TEST_TEMP_DIR/t5-scope.md"; printf '+ .\n' > "$SCOPE"
PLAN="$ART_DIR/plan.json"; printf '{"steps":[]}' > "$PLAN"
DIFF="$ART_DIR/diff.patch"; printf 'no diff\n' > "$DIFF"
MISSING_TEST="$ART_DIR/test-results.json"  # intentionally absent
REVIEW_OUT="$ART_DIR/review.json"

# Stubs: route_to_model returns an approve verdict; apply_scope_redaction
# passes through. render_artifact returns input as-is.
route_to_model() {
    # Last arg is output file path per callsite usage; just write a JSON.
    local out="${!#}"
    printf '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}' > "$out"
    return 0
}
export -f route_to_model
apply_scope_redaction() { cp "$1" "$2"; return 0; }
export -f apply_scope_redaction
render_artifact() { printf '%s' "$2"; }
export -f render_artifact

set +e
_review_run_inner "$SCOPE" "$PLAN" "$DIFF" "$MISSING_TEST" "$REVIEW_OUT" "$ART_DIR" >/dev/null 2>&1
set -e

if grep -q '"type":"review.test_status.missing"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "T5: review.test_status.missing event emitted when test-results.json absent"
else
    assert_fail "T5: review.test_status.missing event" "missing from event log"
fi

print_test_results
