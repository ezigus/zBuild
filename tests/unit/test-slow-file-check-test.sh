#!/usr/bin/env bash
# tests/unit/test-slow-file-check-test.sh — test fails a test file the change
# made far slower than the rest of the suite (ADR-040, amended 2026-10-31).
#
# Why: on #1754's run a new test file took 210 s, against 72 s for the slowest
# file the change did not touch, because the lint it ran forked two greps per
# line of the codebase. Nothing failed for it: the suite still passed or failed
# on its assertions, and every re-run of the file by the acceptance check went
# past its limit and was reported as a problem in the pipeline.
#
# T1 [change] a test file the change added takes more than twice the slowest
#             file it did not touch: a finding naming both files and both times
# T2 [guard]  a changed file under twice the slowest untouched one: no finding
# T3 [guard]  a slow file the change did not touch: no finding
# T4 [guard]  under the floor (a fast suite): no finding
# T5 [guard]  no untouched file was measured (a targeted re-run): no finding
# T6 [change] test's own checks fail the run on it, the finding in test's result
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "test fails a test file the change made far slower (ADR-040)"
setup_test_env "test-slow-file-check"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

R="$TEST_TEMP_DIR/repo"
mkdir -p "$R/tests"
( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
    && printf 'true\n' > tests/old-slow-test.sh && printf 'true\n' > tests/old-fast-test.sh \
    && git add -A && git commit -q -m seed \
    && git checkout -q -b zbuild/issue-1 && printf 'true\n' > tests/new-test.sh \
    && printf 'true # changed\n' >> tests/old-fast-test.sh && git add -A && git commit -q -m change ) >/dev/null 2>&1

STAGE="/tmp/zbuild-test-stage.X"   # the timing log names files under the run's staging copy
LOG="$TEST_TEMP_DIR/test-timing.log"
_timing() {   # _timing <new_ms> <old_fast_ms> <old_slow_ms> — "" leaves a file out
    : > "$LOG"
    printf 'tier 900000 unit\n' >> "$LOG"
    [[ -n "$1" ]] && printf 'file %s %s/tests/new-test.sh\n' "$1" "$STAGE" >> "$LOG"
    [[ -n "$2" ]] && printf 'file %s %s/tests/old-fast-test.sh\n' "$2" "$STAGE" >> "$LOG"
    [[ -n "$3" ]] && printf 'file %s %s/tests/old-slow-test.sh\n' "$3" "$STAGE" >> "$LOG"
    printf 'cpu 1 2 %s/tests/new-test.sh\n' "$STAGE" >> "$LOG"
}
_slow() { _TEST_SLOW_FINDINGS=(); _test_slow_files "$R" "$LOG"; printf '%s\n' "${_TEST_SLOW_FINDINGS[@]+"${_TEST_SLOW_FINDINGS[@]}"}"; }

# ── T1 ───────────────────────────────────────────────────────────────────────
_timing 210229 1000 72000
out="$(_slow)"
assert_eq "[T1] one finding" "1" "$(grep -c . <<< "$out" || true)"
assert_contains "[T1] ...naming the slow file" "$out" "tests/new-test.sh"
assert_contains "[T1] ...and its time" "$out" "210 s"
assert_contains "[T1] ...and the slowest file the change did not touch" "$out" "tests/old-slow-test.sh"
assert_contains "[T1] ...with its time" "$out" "72 s"

# ── T2 ───────────────────────────────────────────────────────────────────────
_timing 120000 1000 72000
assert_eq "[T2] under twice the slowest untouched file: no finding" "" "$(_slow)"

# ── T3 ───────────────────────────────────────────────────────────────────────
_timing 1000 1000 500000
assert_eq "[T3] a slow file the change did not touch: no finding" "" "$(_slow)"

# ── T4 ───────────────────────────────────────────────────────────────────────
_timing 30000 100 1000
assert_eq "[T4] under the floor: no finding" "" "$(_slow)"

# ── T5 ───────────────────────────────────────────────────────────────────────
_timing 210229 1000 ""
assert_eq "[T5] no untouched file measured: no finding" "" "$(_slow)"

# ── T6 ───────────────────────────────────────────────────────────────────────
A="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$A"
export ZBUILD_ARTIFACT_DIR="$A" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
unset ZBUILD_STAGE_INPUTS
_timing 210229 1000 72000; cp "$LOG" "$A/test-timing.log"
stage_result_write "$A/test-results.json" pass "all passed" '{}' >/dev/null 2>&1
shape_floor_run() { stage_result_write "$ZBUILD_ARTIFACT_DIR/shape-floor-result.json" pass ok; }
acceptance_gate_run() { stage_result_write "$ZBUILD_ARTIFACT_DIR/acceptance-gate-result.json" pass ok; }
_test_own_checks test "$TEST_TEMP_DIR/state/pipeline-state.json" "$A/test-results.json" "$R" >/dev/null 2>&1
assert_eq "[T6] test fails" "fail" "$(jq -r '.outcome // "MISSING"' "$A/test-results.json")"
assert_contains "[T6] ...with the finding in its result" \
    "$(jq -r '.data.findings[]?.text // empty' "$A/test-results.json")" "tests/new-test.sh"
assert_contains "[T6] ...and its reason says why" "$(jq -r '.reason // ""' "$A/test-results.json")" "slower"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
