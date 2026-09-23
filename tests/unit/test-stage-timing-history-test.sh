#!/usr/bin/env bash
# test-stage-timing-history-test.sh — the test stage's per-file timing survives
# a later run (#2167).
#
# #1841: the first test stage ran the full suite (20 min, ~700 files); the
# next two were 13-second targeted re-runs. Each run `rm -f`'d test-timing.log
# first, so the run's artifacts held only the last targeted run's handful of
# rows — the full suite's numbers (the ones that would have said whether
# engine-isolation-test.sh timed out again) were gone, and the acceptance
# gate's declared `test_timing` input (it sizes its probes from the measured
# per-file time, #2142) saw a subset.
#
# SPEC-1[change]: a run appends to test-timing.log under a `run <n> <mode>` marker;
#   rows from the previous run are still there afterwards
# SPEC-2[change]: the timing summary folded into test-results.json describes the LAST run only
#   (tier totals are not summed across runs; slowest_files is not a union)
# SPEC-3[guard]:  the acceptance gate's measured bound still sees the earlier full run's
#   slow row after a targeted re-run (it takes the max across rows)
# SPEC-4[change]: a run whose suite writes no timing rows adds no artifact (the parity golden
#   lists no test-timing.log for the mocked run)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test stage: per-file timing survives a later run (#2167)"
setup_test_env "test-timing-history"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"; mkdir -p "$ARTIFACT_DIR" "$ZBUILD_STATE_DIR/runtime"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"
: > "$ARTIFACT_DIR/diff.patch"

# A tiny repo to stage: the plugin rsyncs it and runs the command inside.
REPO_FIXTURE="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO_FIXTURE/tests"
git -C "$REPO_FIXTURE" init -q; git -C "$REPO_FIXTURE" config user.email t@t; git -C "$REPO_FIXTURE" config user.name t
: > "$REPO_FIXTURE/tests/keep"; git -C "$REPO_FIXTURE" add -A; git -C "$REPO_FIXTURE" commit -qm init

PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
OUT="$ARTIFACT_DIR/test-results.json"
LOG="$ARTIFACT_DIR/test-timing.log"

# The "suite": writes the rows run-tests.sh would, then reports like it.
# Run 1 = the full suite (one slow file that hit the 480 s bound, one quick).
FULL_CMD='printf "tier 500000 integration\nfile 480000 $PWD/tests/integration/slow-test.sh\nfile 100 $PWD/tests/unit/a-test.sh\n" >> "$ZBUILD_TEST_TIMING_FILE"; echo "integration: 1/2 passed"; exit 1'
# Run 2 = a targeted re-run of the quick file only.
TARGETED_CMD='printf "tier 200 unit\nfile 120 $PWD/tests/unit/a-test.sh\n" >> "$ZBUILD_TEST_TIMING_FILE"; echo "unit: 1/1 passed"; exit 0'

print_test_section "SPEC-1: a later run does not erase the earlier run's rows"
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$OUT" "$FULL_CMD" >/dev/null 2>&1 || true
assert_file_exists "[SPEC-1] run 1 writes test-timing.log" "$LOG"
assert_contains "[SPEC-1] run 1's slow row is recorded" "$(cat "$LOG")" "file 480000"
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$OUT" "$TARGETED_CMD" >/dev/null 2>&1 || true
assert_contains "[SPEC-1] after run 2 the slow row from run 1 is STILL there" "$(cat "$LOG")" "file 480000"
assert_contains "[SPEC-1] …and run 2's row is there too" "$(cat "$LOG")" "file 120 "
assert_eq "[SPEC-1] each run's rows sit under a run marker" "2" "$(grep -c '^run [0-9]' "$LOG" || true)"
assert_eq "[SPEC-1] …the marker names the run and its mode, and precedes its rows" "run 1 full" "$(sed -n 1p "$LOG")"
assert_eq "[SPEC-1] …the second run gets its own block, labelled run 2 (both runs are full mode here: no red set is supplied)" "run 2 full" "$(grep '^run 2' "$LOG")"

print_test_section "SPEC-2: the folded summary describes the last run only"
_tiers="$(jq -c '.data.timing.tiers // .timing.tiers // {}' "$OUT" 2>/dev/null)"
assert_eq "[SPEC-2] tier totals are the last run's, not a sum across runs" '{"unit":200}' "$_tiers"
_slow="$(jq -r '(.data.timing.slowest_files // .timing.slowest_files // []) | map(.file) | join(",")' "$OUT" 2>/dev/null)"
if grep -q 'slow-test.sh' <<< "$_slow"; then
    assert_fail "[SPEC-2] slowest_files lists the last run's files only" "leaked run 1's slow-test.sh: $_slow"
else
    assert_pass "[SPEC-2] slowest_files lists the last run's files only"
fi

print_test_section "SPEC-3: the measured probe bound still sees the full run's slow row"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true
if declare -F _acceptance_file_timeout >/dev/null 2>&1; then
    _b="$(ZBUILD_NEGCTL_TIMING_LOG="$LOG" ZBUILD_TEST_FILE_TIMEOUT=480 _acceptance_file_timeout "tests/integration/slow-test.sh" 60)"
    assert_eq "[SPEC-3] the slow file's bound is the ceiling, from run 1's row" "480" "$_b"
    _q="$(ZBUILD_NEGCTL_TIMING_LOG="$LOG" _acceptance_file_timeout "tests/unit/a-test.sh" 60)"
    assert_eq "[SPEC-3] the quick file's bound is the stage default" "60" "$_q"
else
    assert_fail "[SPEC-3] _acceptance_file_timeout is sourced" "missing"
fi

# A run whose suite writes no timing adds nothing — not even the file.
rm -f "$LOG"
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$OUT" 'echo "unit: 1/1 passed"; exit 0' >/dev/null 2>&1 || true
assert_file_not_exists "[SPEC-4] a run with no measurements adds no timing artifact" "$LOG"

# ─── SPEC-5 (#2180): the suite's own output survives the stage ──────────────
# The stage extracts ~80 lines into test-failures-summary.md and drops the rest.
# When a test fails ONLY inside this nested stage — per-run-state-isolation T4
# on every suite of #1841 run 35720879137, including the first, before the
# builder had changed anything — there is nothing left to read and the failure
# cannot be diagnosed at all. Keep the raw output as a diagnostic artifact.
print_test_section "SPEC-5: the raw suite output is kept, not just the extract"

RAWLOG="$ARTIFACT_DIR/test-output.log"
rm -f "$RAWLOG"
_FAIL_CMD='echo "a line the extractor does not match"; echo "  ✗ T4: explicit-state run exits 0"; echo "    expected: 0, got: 1"; echo "integration: FAIL tests/integration/per-run-state-isolation-test.sh"; echo "  1 of 19 tests failed"; exit 1'
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$OUT" "$_FAIL_CMD" >/dev/null 2>&1 || true
assert_file_exists "[SPEC-5] a failing suite leaves its raw output on disk" "$RAWLOG"
_raw="$(cat "$RAWLOG" 2>/dev/null || true)"
assert_contains "[SPEC-5] the failing assertion is in it" "$_raw" "T4: explicit-state run exits 0"
assert_contains "[SPEC-5] and the line the extractor never matched" \
    "$_raw" "a line the extractor does not match"

# A passing run keeps its output too: "it passed here and fails there" is the
# comparison that localises an environment-only failure.
rm -f "$RAWLOG"
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$OUT" 'echo "unit: 1/1 passed"; exit 0' >/dev/null 2>&1 || true
assert_file_exists "[SPEC-5] a passing suite keeps its output as well" "$RAWLOG"

# Each run replaces the last — a stale log read as the current failure would be
# worse than none (the #2167 lesson, applied the other way: timing accumulates
# because it is measurement, output replaces because it is one run's evidence).
assert_contains "[SPEC-5] the newest run's output replaces the previous one" \
    "$(cat "$RAWLOG" 2>/dev/null)" "unit: 1/1 passed"
if [[ -s "$RAWLOG" ]] && ! grep -q 'T4: explicit-state' "$RAWLOG" 2>/dev/null; then
    assert_pass "[SPEC-5] no line from the previous run survives"
else
    assert_fail "[SPEC-5] no line from the previous run survives" \
        "$([[ -s "$RAWLOG" ]] && head -3 "$RAWLOG" || echo 'log absent — cannot be clean by being missing')"
fi

# Bounded: a runaway suite must not upload gigabytes. The cap keeps the TAIL —
# a suite that dies mid-way puts the reason at the end — and says it truncated.
rm -f "$RAWLOG"
ZBUILD_TEST_OUTPUT_MAX_BYTES=2000 _test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$OUT" \
    'for i in $(seq 1 400); do echo "filler line $i ................................"; done; echo "THE LAST LINE"; exit 1' \
    >/dev/null 2>&1 || true
_sz="$(wc -c < "$RAWLOG" 2>/dev/null | tr -d " ")"
if [[ "${_sz:-0}" =~ ^[0-9]+$ && "$_sz" -gt 0 && "$_sz" -le 2400 ]]; then
    assert_pass "[SPEC-5] the log is capped (got ${_sz}B for a ~20KB suite)"
else
    assert_fail "[SPEC-5] the log is capped" "got ${_sz}B"
fi
assert_contains "[SPEC-5] the cap keeps the END, where a dying suite says why" \
    "$(cat "$RAWLOG" 2>/dev/null)" "THE LAST LINE"
assert_contains "[SPEC-5] and marks that it truncated" "$(cat "$RAWLOG" 2>/dev/null)" "truncated"

# Declared, so the engine uploads it and a consumer could resolve it.
assert_contains "[SPEC-5] the manifest declares the log as an output" \
    "$(cat "$PLUGIN_DIR/manifest.yaml" 2>/dev/null)" "test-output.log"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
