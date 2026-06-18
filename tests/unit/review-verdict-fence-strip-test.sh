#!/usr/bin/env bash
# Unit test (#933): review plugin strips code fences from LLM verdict.
#
# SPEC-1: ```json-fenced approve + trailing JSON example → approve
# SPEC-2: plain ```-fenced approve + prose-before-fence + trailing example → approve
# SPEC-3: fenced request_changes + trailing approve example → request_changes
# Control: unfenced approve (regression guard) → approve
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "review plugin fence strip (#933)"
setup_test_env "review-fence-strip-933"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# Source the event bus and wire emit_event.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
emit_event() { eb_emit_event "$@"; }
export -f emit_event

# Source the review plugin (loads helpers, llm-agent, prompt-overrides, etc.)
# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# apply_scope_redaction: just copy input to output (no redaction needed in test).
apply_scope_redaction() { cp "$1" "$2"; return 0; }
export -f apply_scope_redaction

# Minimal shared artifacts reused across all test cases.
SCOPE="$TEST_TEMP_DIR/scope.md";        printf '+ .\n' > "$SCOPE"
PLAN="$TEST_TEMP_DIR/plan.json";        printf '{"steps":[]}' > "$PLAN"
DIFF="$TEST_TEMP_DIR/diff.patch";       printf 'diff --git a/x.sh b/x.sh\n' > "$DIFF"
# test-results.json with verdict=pass so ADR-019 fail-closed does not coerce
# an approve verdict to request_changes.
TEST_RESULTS="$TEST_TEMP_DIR/test-results.json"
printf '{"verdict":"pass","passed":5,"failed":0}' > "$TEST_RESULTS"

# run_and_get_verdict <art_dir>
# Calls _review_run_inner with the currently exported route_to_model mock and
# returns the .verdict field from the written review.json.
run_and_get_verdict() {
    local art_dir="$1"
    mkdir -p "$art_dir"
    local review_out="$art_dir/review.json"
    set +e
    _review_run_inner "$SCOPE" "$PLAN" "$DIFF" "$TEST_RESULTS" "$review_out" "$art_dir" \
        >/dev/null 2>&1
    set -e
    jq -r '.verdict // empty' "$review_out" 2>/dev/null || true
}

# ─── T1 [SPEC-1]: ```json-fenced approve + trailing JSON example → approve ────
# Primary failure mode: model wraps verdict in ```json…``` but emits a trailing
# JSON snippet. Without the fix, "LAST wins" in extract_first_json_object picks
# the trailing example and the verdict defaults to request_changes.
route_to_model() {
    printf '%s\n' '```json'
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"lgtm"}'
    printf '%s\n' '```'
    printf '%s\n' '{"verdict":"request_changes","confidence":0.3,"issues":["trailing example"],"summary":"example"}'
    return 0
}
export -f route_to_model
: > "$ZBUILD_EVENTS_JSONL"
verdict="$(run_and_get_verdict "$TEST_TEMP_DIR/t1-art")"
assert_eq "[SPEC-1] json-fenced approve + trailing example → approve" "approve" "$verdict"

# ─── T2 [SPEC-2]: plain ```-fenced approve + prose-before-fence → approve ─────
# Prose before the fence defeats the ^-anchored pre-pass inside
# extract_first_json_object; combined with a trailing example the wrong object
# wins. The fence-extraction step detects any matching fence line, not just at
# the buffer start, so it handles both failure modes.
route_to_model() {
    printf '%s\n' 'My analysis of the diff:'
    printf '%s\n' '```'
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"lgtm"}'
    printf '%s\n' '```'
    printf '%s\n' '{"verdict":"request_changes","confidence":0.3,"issues":["bad code"],"summary":"bad"}'
    return 0
}
export -f route_to_model
: > "$ZBUILD_EVENTS_JSONL"
verdict="$(run_and_get_verdict "$TEST_TEMP_DIR/t2-art")"
assert_eq "[SPEC-2] plain-fenced approve + prose-before + trailing → approve" "approve" "$verdict"

# ─── T3 (control): unfenced approve → approve (regression guard) ──────────────
# The fix only fires when a fence line is detected; the unfenced path must be
# unchanged so this exercises the real extract_first_json_object on plain JSON.
route_to_model() {
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"lgtm"}'
    return 0
}
export -f route_to_model
: > "$ZBUILD_EVENTS_JSONL"
verdict="$(run_and_get_verdict "$TEST_TEMP_DIR/t3-art")"
assert_eq "[SPEC-4] T3: unfenced approve (control) → approve" "approve" "$verdict"

# ─── T4 [SPEC-3]: fenced request_changes + trailing approve example → request_changes
# Verifies no silent promotion: the fence body is authoritative even when the
# trailing example outside the fence would be a "better" (approve) verdict.
# Without the fix, "LAST wins" picks the trailing approve and the verdict is
# silently promoted.
route_to_model() {
    printf '%s\n' '```json'
    printf '%s\n' '{"verdict":"request_changes","confidence":0.8,"issues":["needs work"],"summary":"fix needed"}'
    printf '%s\n' '```'
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"looks good"}'
    return 0
}
export -f route_to_model
: > "$ZBUILD_EVENTS_JSONL"
verdict="$(run_and_get_verdict "$TEST_TEMP_DIR/t4-art")"
assert_eq "[SPEC-3] fenced request_changes + trailing approve → request_changes" "request_changes" "$verdict"

print_test_results
