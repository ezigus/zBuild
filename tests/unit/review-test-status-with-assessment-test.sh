#!/usr/bin/env bash
# Unit test (#569): _review_derive_test_status prefers test-assessment.json
# over test-results.json per ADR-019 §7 amendment (#572).
#
# Precedence:
#   assessment.verdict=pass         → review reads "passed"
#   assessment.verdict=fail         → "failed"
#   assessment.verdict=error        → "failed"
#   assessment.verdict=inconclusive → "unknown"
#   assessment absent               → fall back to test-results.json verdict
#   assessment malformed            → fall back to test-results.json verdict
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review _review_derive_test_status precedence with test-assessment (#569)"
setup_test_env "review-test-status-assessment-569"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
emit_event() { eb_emit_event "$@"; }
export -f emit_event

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# Helper: build a fresh artifact dir with optional assessment + test files.
# Args: <name> [assessment_json] [test_json]
mk_case() {
    local name="$1" assessment="${2:-}" test_json="${3:-}"
    local dir="$TEST_TEMP_DIR/$name"
    mkdir -p "$dir"
    [[ -n "$assessment" ]] && printf '%s' "$assessment" > "$dir/test-assessment.json"
    [[ -n "$test_json" ]] && printf '%s' "$test_json" > "$dir/test-results.json"
    printf '%s' "$dir"
}

# ─── Test 1: assessment.verdict=pass → "passed" ──────────────────────────────
dir="$(mk_case t1 '{"verdict":"pass"}' '{"verdict":"fail"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T1: assessment pass beats test fail → 'passed'" "passed" "$out"

# ─── Test 2: assessment.verdict=fail → "failed" ──────────────────────────────
dir="$(mk_case t2 '{"verdict":"fail"}' '{"verdict":"pass"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T2: assessment fail beats test pass → 'failed'" "failed" "$out"

# ─── Test 3: assessment.verdict=error → "failed" ─────────────────────────────
dir="$(mk_case t3 '{"verdict":"error"}' '{"verdict":"pass"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T3: assessment error → 'failed'" "failed" "$out"

# ─── Test 4: assessment.verdict=inconclusive → "unknown" ─────────────────────
dir="$(mk_case t4 '{"verdict":"inconclusive"}' '{"verdict":"pass"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T4: assessment inconclusive → 'unknown'" "unknown" "$out"

# ─── Test 5: assessment absent + test=pass → "passed" (fallback) ─────────────
dir="$(mk_case t5 '' '{"verdict":"pass"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T5: no assessment, test pass → 'passed' (fallback)" "passed" "$out"

# ─── Test 6: assessment absent + test=fail → "failed" (fallback) ─────────────
dir="$(mk_case t6 '' '{"verdict":"fail"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T6: no assessment, test fail → 'failed' (fallback)" "failed" "$out"

# ─── Test 7: malformed assessment + test=fail → falls back → "failed" ────────
dir="$(mk_case t7 '{not valid json' '{"verdict":"fail"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T7: malformed assessment falls back to test → 'failed'" "failed" "$out"

# ─── Test 8: assessment present but verdict missing → falls back ─────────────
dir="$(mk_case t8 '{"summary":"no verdict here"}' '{"verdict":"pass"}')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T8: assessment lacking .verdict falls back to test → 'passed'" "passed" "$out"

# ─── Test 9: assessment.verdict=pass + no test-results → "passed" ────────────
# Assessment alone should be enough (the LLM stage already adjudicated).
dir="$(mk_case t9 '{"verdict":"pass"}' '')"
out="$(_review_derive_test_status "$dir/test-results.json")"
assert_eq "T9: assessment pass alone (no test-results) → 'passed'" "passed" "$out"

print_test_results
