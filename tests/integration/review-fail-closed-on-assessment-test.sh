#!/usr/bin/env bash
# Integration test (#569): drive _review_run_inner with a test-assessment.json
# fixture where assessment.verdict=fail. The LLM stub returns approve; the
# ADR-019 §485 fail-closed gate (now reading from assessment per §7 amendment
# in #572) must coerce approve → request_changes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review fail-closed on test-assessment.verdict=fail (#569)"
setup_test_env "review-fail-closed-assessment-569"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
emit_event() { eb_emit_event "$@"; }
export -f emit_event

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# ─── Stubs ───────────────────────────────────────────────────────────────────
# LLM router returns an approve verdict. Output is captured by the caller via
# command substitution — print, don't write to a file.
route_to_model() {
    printf '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"diff looks correct"}'
    return 0
}
export -f route_to_model
apply_scope_redaction() { cp "$1" "$2"; return 0; }
export -f apply_scope_redaction
render_artifact() { printf '%s' "$2"; }
export -f render_artifact

# ─── Case 1: assessment.verdict=fail + test.verdict=pass → coerced ───────────
# This is the canonical regression: test-results says pass (or is stale) but
# the assessment LLM ruled fail. Review MUST honor assessment and coerce.
: > "$ZBUILD_EVENTS_JSONL"
ART_DIR="$TEST_TEMP_DIR/c1-art"; mkdir -p "$ART_DIR"
SCOPE="$TEST_TEMP_DIR/c1-scope.md"; printf '+ .\n' > "$SCOPE"
PLAN="$ART_DIR/plan.json";   printf '{"steps":[]}' > "$PLAN"
DIFF="$ART_DIR/diff.patch";  printf 'no diff\n'    > "$DIFF"
TEST="$ART_DIR/test-results.json";    printf '{"verdict":"pass","passed":3,"failed":0}' > "$TEST"
ASSESS="$ART_DIR/test-assessment.json"; printf '{"verdict":"fail","summary":"3/3 logged pass but suite skipped target file"}' > "$ASSESS"
REVIEW_OUT="$ART_DIR/review.json"

set +e
_review_run_inner "$SCOPE" "$PLAN" "$DIFF" "$TEST" "$REVIEW_OUT" "$ART_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "C1: _review_run_inner returns 0" "0" "$rc"

if [[ -f "$REVIEW_OUT" ]]; then
    verdict="$(jq -r '.verdict' "$REVIEW_OUT" 2>/dev/null)"
    assert_eq "C1: assessment=fail coerces approve → request_changes" "request_changes" "$verdict"
else
    assert_fail "C1: review.json produced" "file missing"
fi

if grep -q '"type":"review.test_status.coerced"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "C1: review.test_status.coerced event emitted"
else
    assert_fail "C1: review.test_status.coerced event" "missing from event log"
fi

# ─── Case 2: assessment.verdict=pass + test.verdict=fail → approve stands ────
# Inverse: stale test-results.json says fail but the assessment ruled pass
# (the LLM understood the failure was unrelated/flaky). Review honors the
# assessment and keeps approve.
: > "$ZBUILD_EVENTS_JSONL"
ART_DIR="$TEST_TEMP_DIR/c2-art"; mkdir -p "$ART_DIR"
SCOPE="$TEST_TEMP_DIR/c2-scope.md"; printf '+ .\n' > "$SCOPE"
PLAN="$ART_DIR/plan.json";   printf '{"steps":[]}' > "$PLAN"
DIFF="$ART_DIR/diff.patch";  printf 'no diff\n'    > "$DIFF"
TEST="$ART_DIR/test-results.json";    printf '{"verdict":"fail"}' > "$TEST"
ASSESS="$ART_DIR/test-assessment.json"; printf '{"verdict":"pass","summary":"unrelated flake"}' > "$ASSESS"
REVIEW_OUT="$ART_DIR/review.json"

set +e
_review_run_inner "$SCOPE" "$PLAN" "$DIFF" "$TEST" "$REVIEW_OUT" "$ART_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "C2: _review_run_inner returns 0" "0" "$rc"
if [[ -f "$REVIEW_OUT" ]]; then
    verdict="$(jq -r '.verdict' "$REVIEW_OUT" 2>/dev/null)"
    assert_eq "C2: assessment=pass keeps LLM approve" "approve" "$verdict"
fi

# ─── Case 3: assessment.verdict=inconclusive → coerced to request_changes ────
: > "$ZBUILD_EVENTS_JSONL"
ART_DIR="$TEST_TEMP_DIR/c3-art"; mkdir -p "$ART_DIR"
SCOPE="$TEST_TEMP_DIR/c3-scope.md"; printf '+ .\n' > "$SCOPE"
PLAN="$ART_DIR/plan.json";   printf '{"steps":[]}' > "$PLAN"
DIFF="$ART_DIR/diff.patch";  printf 'no diff\n'    > "$DIFF"
TEST="$ART_DIR/test-results.json";    printf '{"verdict":"pass"}' > "$TEST"
ASSESS="$ART_DIR/test-assessment.json"; printf '{"verdict":"inconclusive"}' > "$ASSESS"
REVIEW_OUT="$ART_DIR/review.json"

set +e
_review_run_inner "$SCOPE" "$PLAN" "$DIFF" "$TEST" "$REVIEW_OUT" "$ART_DIR" >/dev/null 2>&1
set -e
if [[ -f "$REVIEW_OUT" ]]; then
    verdict="$(jq -r '.verdict' "$REVIEW_OUT" 2>/dev/null)"
    assert_eq "C3: assessment=inconclusive → coerced to request_changes" "request_changes" "$verdict"
fi

print_test_results
