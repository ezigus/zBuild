#!/usr/bin/env bash
# Integration: plugins/tool/test parser pattern bank (#584)
#
# Drives _test_run_inner with stubbed test commands emitting each known
# runner shape, asserts:
#   - test-results.json reflects the parsed counts (or null on fail-safe)
#   - the verdict + reason field are honest
#   - the no-op silent-failure path still triggers as `summary_unavailable`
#     because empty output cannot be recognized by any pattern.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test-plugin parser → test-results.json (#584)"

setup_test_env "test-plugin-summary-format"

# Isolated event bus
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"
ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# Tiny git repo + empty diff so apply --check --allow-empty succeeds
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" -c user.name=t -c user.email=t@t \
    commit --allow-empty -m init -q

EMPTY_PATCH="$ARTIFACT_DIR/diff.patch"
: > "$EMPTY_PATCH"  # zero-byte; --allow-empty handles it

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

_run_with_cmd() {
    local cmd="$2" out_json="$ARTIFACT_DIR/test-results-${1}.json"
    rm -f "$out_json"
    _test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$out_json" "$cmd" \
        >/dev/null 2>&1 || true
    printf '%s\n' "$out_json"
}

# ───────────────────────────────────────────────────────────────────────────
# jest-shaped output
# ───────────────────────────────────────────────────────────────────────────
print_test_section "1. jest-shaped output parsed correctly"

JEST_CMD=$'printf "%s\\n" "Test Suites: 3 failed, 12 passed, 15 total" "Tests:       18 failed, 108 passed, 126 total" "Snapshots:   0 total"; exit 1'
JSON="$(_run_with_cmd jest "$JEST_CMD")"

assert_file_exists "jest: artifact written" "$JSON"
assert_eq "jest: verdict=fail" "fail"     "$(jq -r '.verdict' "$JSON")"
assert_eq "jest: passed=108"   "108"      "$(jq -r '.passed'  "$JSON")"
assert_eq "jest: failed=18"    "18"       "$(jq -r '.failed'  "$JSON")"

# ───────────────────────────────────────────────────────────────────────────
# pytest-shaped output
# ───────────────────────────────────────────────────────────────────────────
print_test_section "2. pytest-shaped output parsed correctly"

PYTEST_CMD=$'printf "%s\\n" "============================= test session starts =============================" "....FFF......." "=========================== 3 failed, 42 passed in 1.23s ==========================="; exit 1'
JSON="$(_run_with_cmd pytest "$PYTEST_CMD")"

assert_eq "pytest: verdict=fail" "fail" "$(jq -r '.verdict' "$JSON")"
assert_eq "pytest: passed=42"    "42"   "$(jq -r '.passed'  "$JSON")"
assert_eq "pytest: failed=3"     "3"    "$(jq -r '.failed'  "$JSON")"

# ───────────────────────────────────────────────────────────────────────────
# run-all.sh-shaped output (real shape from scripts/run-tests.sh)
# ───────────────────────────────────────────────────────────────────────────
print_test_section "3. run-all-shaped output parsed correctly"

RUNALL_CMD=$'printf "%s\\n" "unit: FAIL /repo/tests/unit/foo-test.sh" "unit: 108/126 passed" "integration: 75/77 passed" "e2e: 7/7 passed" "golden: 1/1 passed"; exit 1'
JSON="$(_run_with_cmd runall "$RUNALL_CMD")"

assert_eq "runall: verdict=fail" "fail" "$(jq -r '.verdict' "$JSON")"
assert_eq "runall: passed=191"   "191"  "$(jq -r '.passed'  "$JSON")"
assert_eq "runall: failed=1"     "1"    "$(jq -r '.failed'  "$JSON")"

# ───────────────────────────────────────────────────────────────────────────
# Fail-safe: gibberish (no pattern matches) → summary_unavailable
# ───────────────────────────────────────────────────────────────────────────
print_test_section "4. unrecognized output → reason=summary_unavailable + null counts"

GIBBERISH_CMD=$'printf "%s\\n" "make: *** [Makefile:42: test] Error 1" "ld: symbol not found"; exit 2'
JSON="$(_run_with_cmd gibberish "$GIBBERISH_CMD")"

assert_eq "failsafe: verdict=error"             "error"                "$(jq -r '.verdict' "$JSON")"
assert_eq "failsafe: reason=summary_unavailable" "summary_unavailable" "$(jq -r '.reason'  "$JSON")"
assert_eq "failsafe: passed is null"            "null"                 "$(jq -r '.passed'  "$JSON")"
assert_eq "failsafe: failed is null"            "null"                 "$(jq -r '.failed'  "$JSON")"

# ───────────────────────────────────────────────────────────────────────────
# Empty output (e.g. `true`) — fail-safe SUPERSEDES the old #485 no-op
# guard, but the same fail-closed outcome holds: verdict=error.
# ───────────────────────────────────────────────────────────────────────────
print_test_section "5. empty output (no-op cmd) → verdict=error"

JSON="$(_run_with_cmd noop "true")"

assert_eq "noop: verdict=error" "error" "$(jq -r '.verdict' "$JSON")"
# Either #485 no-op reason or new summary_unavailable reason is acceptable;
# what matters is verdict=error so review fails closed.

print_test_results
