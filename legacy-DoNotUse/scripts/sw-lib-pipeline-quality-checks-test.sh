#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-quality-checks test — Unit tests for quality     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-quality-checks Tests"

setup_test_env "sw-lib-pipeline-quality-checks-test"
_test_cleanup_hook() { cleanup_test_env; }

# Set up quality checks env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export SCRIPT_DIR="$SCRIPT_DIR"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export BASE_BRANCH="main"
export ISSUE_NUMBER="42"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline-config.json"
export TEST_CMD=""
export GOAL="Test goal"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$PROJECT_ROOT"

# Provide stubs (redirect to /dev/null so result=$(...) captures only the echoed value)
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
emit_event() { :; }
# _timeout is normally from compat.sh (sourced by sw-pipeline.sh); stub it here
_timeout() { shift; "$@"; }

# parse_coverage_from_output is used by quality_check_coverage - stub it
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    grep -oE '[0-9]{1,3}\.[0-9]*|[0-9]{1,3}' "$log_file" 2>/dev/null | head -1 || true
}

# detect_test_cmd used by run_e2e_validation
detect_test_cmd() { echo ""; }

# Minimal pipeline config
echo '{"stages":[{"id":"test","config":{"coverage_min":0}}]}' > "$PIPELINE_CONFIG"

# Source compat.sh for file_mtime() and date_to_epoch() used by pipeline_artifact_is_fresh()
source "$SCRIPT_DIR/lib/compat.sh"

# Source the lib (clear guard)
_PIPELINE_QUALITY_CHECKS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# run_test_coverage_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_test_coverage_check"

# No TEST_CMD → skip
unset TEST_CMD
result=$(run_test_coverage_check 2>/dev/null)
assert_eq "No TEST_CMD returns skip" "skip" "$result"

# TEST_CMD that outputs coverage (function echoes the percentage at end)
export TEST_CMD="echo 'Statements : 85% coverage'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Extracts coverage from Jest/Istanbul format" "85" "$result"

# Alternative format - coverage: XX%
export TEST_CMD="echo 'coverage: 90%'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Extracts coverage from coverage format" "90" "$result"

# Failing test command
export TEST_CMD="false"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Failing test returns 0" "0" "$result"

# Cached coverage from test stage — skips running TEST_CMD
echo '{"coverage_pct": 75}' > "$ARTIFACTS_DIR/test-coverage.json"
export TEST_CMD="exit 1"  # would fail if actually run
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Returns cached coverage without running tests" "75" "$result"

# Invalid cache value falls back to running TEST_CMD
echo '{"coverage_pct": "bad"}' > "$ARTIFACTS_DIR/test-coverage.json"
export TEST_CMD="echo 'coverage: 60%'"
result=$(run_test_coverage_check 2>/dev/null | tail -1)
assert_eq "Invalid cache falls back to running tests" "60" "$result"

rm -f "$ARTIFACTS_DIR/test-coverage.json"

# ═══════════════════════════════════════════════════════════════════════════════
# run_e2e_validation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_e2e_validation"

rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/e2e-validation.log"

# No test-results.log and passing TEST_CMD → runs and passes
export TEST_CMD="echo ok"
if run_e2e_validation 2>/dev/null; then
    assert_pass "run_e2e_validation passes when no log and TEST_CMD succeeds"
else
    assert_fail "run_e2e_validation: no log, passing cmd"
fi

# No test-results.log and failing TEST_CMD → runs and fails
rm -f "$ARTIFACTS_DIR/test-results.log"
export TEST_CMD="exit 1"
if run_e2e_validation 2>/dev/null; then
    assert_fail "run_e2e_validation: no log, failing cmd should fail"
else
    assert_pass "run_e2e_validation fails when no log and TEST_CMD fails"
fi

# Passing test-results.log → skips re-run (TEST_CMD would fail if run)
echo "10 tests passed, 0 failures" > "$ARTIFACTS_DIR/test-results.log"
export TEST_CMD="exit 1"
if run_e2e_validation 2>/dev/null; then
    assert_pass "run_e2e_validation skips re-run when log shows passing"
else
    assert_fail "run_e2e_validation: passing log should skip re-run"
fi

# Failing test-results.log → re-runs TEST_CMD
echo "1 failed" > "$ARTIFACTS_DIR/test-results.log"
export TEST_CMD="echo ok"
if run_e2e_validation 2>/dev/null; then
    assert_pass "run_e2e_validation re-runs when log shows failures"
else
    assert_fail "run_e2e_validation: failing log should re-run tests"
fi

rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/e2e-validation.log"

# ═══════════════════════════════════════════════════════════════════════════════
# run_bash_compat_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_bash_compat_check"

mock_git
# With mock_git (no changed .sh files), returns 0
cd "$PROJECT_ROOT"
result=$(run_bash_compat_check 2>/dev/null | tail -1)
cd - >/dev/null
assert_eq "No changed .sh files returns 0" "0" "${result:-0}"

# ═══════════════════════════════════════════════════════════════════════════════
# run_new_function_test_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_new_function_test_check"

cd "$PROJECT_ROOT"
result=$(run_new_function_test_check 2>/dev/null)
assert_eq "No new functions in diff returns 0" "0" "$result"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# run_atomic_write_check
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "run_atomic_write_check"

cd "$PROJECT_ROOT"
result=$(run_atomic_write_check 2>/dev/null)
assert_eq "No state/config changes returns 0" "0" "$result"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_coverage
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_coverage"

# No test-results.log → skip (returns 0)
rm -f "$ARTIFACTS_DIR/test-results.log"
if quality_check_coverage 2>/dev/null; then
    assert_pass "quality_check_coverage passes when no test log"
else
    assert_fail "quality_check_coverage"
fi

# Create test-results.log with coverage
echo "Statements : 82.5%
Lines : 80%
Test Results: 10 passed" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_coverage 2>/dev/null; then
    assert_pass "quality_check_coverage passes with coverage data"
else
    assert_fail "quality_check_coverage"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_security
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_security"

cd "$PROJECT_ROOT"
rm -f package.json requirements.txt Cargo.toml pyproject.toml
if quality_check_security 2>/dev/null; then
    assert_pass "quality_check_security skips when no audit tool"
else
    assert_fail "quality_check_security"
fi
assert_file_exists "Creates security-audit.log" "$ARTIFACTS_DIR/security-audit.log"
content=$(cat "$ARTIFACTS_DIR/security-audit.log")
assert_contains "Audit log has content" "$content" "No audit tool"
cd - >/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_bundle_size
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_bundle_size"

cd "$PROJECT_ROOT"
rm -rf dist build out .next target
if quality_check_bundle_size 2>/dev/null; then
    assert_pass "quality_check_bundle_size skips when no build dir"
else
    assert_fail "quality_check_bundle_size"
fi
cd - >/dev/null

# With build dir
mkdir -p "$PROJECT_ROOT/dist"
echo "mock bundle content" > "$PROJECT_ROOT/dist/bundle.js"
if quality_check_bundle_size 2>/dev/null; then
    assert_pass "quality_check_bundle_size passes with build dir"
else
    assert_fail "quality_check_bundle_size"
fi
assert_file_exists "Creates bundle-metrics.log" "$ARTIFACTS_DIR/bundle-metrics.log"

# ═══════════════════════════════════════════════════════════════════════════════
# quality_check_perf_regression
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quality_check_perf_regression"

rm -f "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression skips without test log"
else
    assert_fail "quality_check_perf_regression"
fi

echo "passed in 12.34s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression with duration"
else
    assert_fail "quality_check_perf_regression"
fi

# --- Issue #398: partial-float / zero duration validation ---
# Each input uses a framework-realistic prefix to exercise the specific extraction path.

# pytest path (line ~372): ".34" passes jq tonumber but silently corrupts history
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "passed in .34s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression rejects pytest leading-dot float (passed in .34s)"
else
    assert_fail "quality_check_perf_regression rejects pytest leading-dot float (passed in .34s)"
fi
assert_contains "metrics log signals rejection for leading-dot float" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Duration not parseable"

# pytest path: "0." passes jq tonumber as 0, corrupts history with meaningless zero
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "passed in 0.s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression rejects pytest trailing dot (passed in 0.s)"
else
    assert_fail "quality_check_perf_regression rejects pytest trailing dot (passed in 0.s)"
fi
assert_contains "metrics log signals rejection for trailing-dot float" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Duration not parseable"

# Jest path (line ~369): lone "." crashes jq (exit 5), leaves history stale
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "Time: . s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression rejects Jest lone dot (Time: . s)"
else
    assert_fail "quality_check_perf_regression rejects Jest lone dot (Time: . s)"
fi
assert_contains "metrics log signals rejection for Jest lone dot" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Duration not parseable"

# Generic fallback path (line ~378): "..." crashes jq (exit 5)
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "...s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression rejects multiple dots (...s)"
else
    assert_fail "quality_check_perf_regression rejects multiple dots (...s)"
fi
assert_contains "metrics log signals rejection for multiple dots" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Duration not parseable"

# Zero duration: "0" is syntactically valid for jq but a meaningless baseline
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "passed in 0s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression rejects zero duration (passed in 0s)"
else
    assert_fail "quality_check_perf_regression rejects zero duration (passed in 0s)"
fi
assert_contains "metrics log signals rejection for zero duration" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Duration not parseable"

# Zero-valued with alternate encoding: "0.00" also numerically zero
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "passed in 0.00s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression rejects zero-valued 0.00 (passed in 0.00s)"
else
    assert_fail "quality_check_perf_regression rejects zero-valued 0.00 (passed in 0.00s)"
fi
assert_contains "metrics log signals rejection for 0.00 duration" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Duration not parseable"

# Valid float via Jest pattern: must be accepted and return 0
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/perf-metrics.log"
echo "Time: 12.34 s" > "$ARTIFACTS_DIR/test-results.log"
if quality_check_perf_regression 2>/dev/null; then
    assert_pass "quality_check_perf_regression accepts valid float (Time: 12.34 s)"
else
    assert_fail "quality_check_perf_regression accepts valid float (Time: 12.34 s)"
fi
assert_contains "metrics log records accepted duration" \
    "$(cat "$ARTIFACTS_DIR/perf-metrics.log" 2>/dev/null)" "Test duration: 12.34s"

# Silent-corruption guard: seed 3 valid history entries, feed a malformed duration,
# assert the history file entry count is unchanged (fix prevents the corrupt append).
_perf_hist_dir="${HOME}/.shipwright/baselines/$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12)"
_perf_hist_file="${_perf_hist_dir}/perf-history.json"
mkdir -p "$_perf_hist_dir"
echo '{"durations":[10.0,11.0,12.0],"updated":"2026-01-01T00:00:00Z"}' > "$_perf_hist_file"
_orig_count=$(jq '.durations | length' "$_perf_hist_file" 2>/dev/null || echo "0")
rm -f "$ARTIFACTS_DIR/test-results.log"
echo "passed in .34s" > "$ARTIFACTS_DIR/test-results.log"
quality_check_perf_regression 2>/dev/null || true
_post_count=$(jq '.durations | length' "$_perf_hist_file" 2>/dev/null || echo "0")
if [[ "$_orig_count" == "$_post_count" ]]; then
    assert_pass "quality_check_perf_regression does not corrupt perf history on bad duration"
else
    assert_fail "quality_check_perf_regression does not corrupt perf history on bad duration"
fi
rm -f "$_perf_hist_file"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_test_status / pipeline_test_passed
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_test_status / pipeline_test_passed"

# Test 1: Sidecar passing
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
result=$(pipeline_test_status 2>/dev/null)
assert_eq "pipeline_test_status returns 0 when sidecar passed" "0" "$result"
if pipeline_test_passed 2>/dev/null; then
    assert_pass "pipeline_test_passed exits 0 when sidecar passed"
else
    assert_fail "pipeline_test_passed should exit 0 when sidecar shows pass"
fi

# Test 2: Sidecar failing
echo '{"exit_code":1,"passed":false,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
result=$(pipeline_test_status 2>/dev/null)
assert_eq "pipeline_test_status returns 1 when sidecar failed" "1" "$result"
if pipeline_test_passed 2>/dev/null; then
    assert_fail "pipeline_test_passed should exit non-zero when sidecar shows fail"
else
    assert_pass "pipeline_test_passed exits non-zero when sidecar failed"
fi

# Test 3: Sidecar missing
rm -f "$ARTIFACTS_DIR/test-results.status.json"
if pipeline_test_status 2>/dev/null; then
    assert_fail "pipeline_test_status should exit non-zero when sidecar missing"
else
    assert_pass "pipeline_test_status exits non-zero when sidecar missing"
fi
if pipeline_test_passed 2>/dev/null; then
    assert_fail "pipeline_test_passed should exit non-zero when sidecar missing"
else
    assert_pass "pipeline_test_passed exits non-zero when sidecar missing"
fi

# Test 4: Regression test — sidecar with noisy log (Terminated: 15, no pass markers)
# This is the exact false-positive from the issue: log has noise but sidecar says pass
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
echo "Running tests...
Test 1: PASS
Test 2: PASS
Terminated: 15
Cleanup done" > "$ARTIFACTS_DIR/test-results.log"
# DoD logic should detect pass via sidecar (not grep)
if pipeline_test_passed 2>/dev/null; then
    assert_pass "pipeline_test_passed uses sidecar even with noisy log"
else
    assert_fail "pipeline_test_passed should trust sidecar over noisy log"
fi

# Test 5: Regression test — sidecar wins over FAIL substring (Processing FAIL_SAFE_MODE.md)
# Another false-positive: log contains "FAIL" as substring but sidecar says pass
rm -f "$ARTIFACTS_DIR/test-results.log" "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' > "$ARTIFACTS_DIR/test-results.status.json"
echo "Processing FAIL_SAFE_MODE.md
Running tests...
All tests passed
Exit code: 0" > "$ARTIFACTS_DIR/test-results.log"
# DoD logic should detect pass via sidecar (not grep false-positive on FAIL_SAFE)
if pipeline_test_passed 2>/dev/null; then
    assert_pass "pipeline_test_passed ignores FAIL substring in filenames"
else
    assert_fail "pipeline_test_passed should trust sidecar over FAIL substring"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_artifact_is_fresh / freshness-aware pipeline_test_status
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_artifact_is_fresh / freshness-aware pipeline_test_status"

_FRESH_EPOCH="$(date +%s)"

# ── F1: Backward compat — PIPELINE_RUN_EPOCH=0 bypasses freshness check ──────
PIPELINE_RUN_EPOCH=0
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":1,"passed":false,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "PIPELINE_RUN_EPOCH=0: stale sidecar reads through (pass-through)" "1" "$_fresh_result"

# ── F2: Fresh sidecar via finished_at >= epoch ────────────────────────────────
PIPELINE_RUN_EPOCH="$(( _FRESH_EPOCH - 300 ))"   # epoch = 5 min ago
_NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
rm -f "$ARTIFACTS_DIR/test-results.status.json"
printf '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"%s"}\n' \
    "$_NOW_ISO" > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null)
assert_eq "Fresh sidecar (finished_at >= epoch): returns exit code" "0" "$_fresh_result"

# ── F3: Stale sidecar via finished_at < epoch — treated as missing ────────────
PIPELINE_RUN_EPOCH="$_FRESH_EPOCH"   # epoch = now; "2026-04-11" is yesterday
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "Stale sidecar (finished_at < epoch): treated as missing, no output" "" "$_fresh_result"
if pipeline_test_passed 2>/dev/null; then
    assert_fail "pipeline_test_passed should return non-zero for stale sidecar"
else
    assert_pass "pipeline_test_passed rejects stale sidecar"
fi

# ── F4: THE BUG — stale failing sidecar must not produce AUDIT:FAIL ──────────
# Prior to fix: exit_code:1 from old run leaked into DoD → false AUDIT:FAIL
PIPELINE_RUN_EPOCH="$_FRESH_EPOCH"   # epoch = now
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":1,"passed":false,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "Bug: stale failing sidecar returns empty (not '1'), prevents AUDIT:FAIL" "" "$_fresh_result"

# ── F5: No finished_at field — falls back to mtime; new file = fresh ──────────
PIPELINE_RUN_EPOCH="$(( _FRESH_EPOCH - 300 ))"   # epoch = 5 min ago
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
# file was just created → mtime >= epoch → fresh
_fresh_result=$(pipeline_test_status 2>/dev/null)
assert_eq "No finished_at: newly-created file is fresh via mtime fallback" "0" "$_fresh_result"

# ── F6: No finished_at field, old mtime — stale via mtime fallback ────────────
PIPELINE_RUN_EPOCH="$_FRESH_EPOCH"   # epoch = now
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
# Set mtime to a date far in the past (Jan 1, 2026 00:00)
touch -t "202601010000.00" "$ARTIFACTS_DIR/test-results.status.json" 2>/dev/null || true
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "No finished_at: old mtime file is stale" "" "$_fresh_result"

# ── F7: Upgrade compat — resume with old state (PIPELINE_RUN_EPOCH unset) ─────
# Simulates a resumed pipeline from a state file written before this fix.
# PIPELINE_RUN_EPOCH will be empty → treated as 0 → pass-through (no false rejection).
unset PIPELINE_RUN_EPOCH
rm -f "$ARTIFACTS_DIR/test-results.status.json"
echo '{"exit_code":0,"passed":true,"cmd":"npm test","finished_at":"2026-04-11T12:00:00Z"}' \
    > "$ARTIFACTS_DIR/test-results.status.json"
_fresh_result=$(pipeline_test_status 2>/dev/null) || true
assert_eq "Upgrade compat: unset PIPELINE_RUN_EPOCH reads sidecar (pass-through)" "0" "$_fresh_result"

# Restore to safe default
export PIPELINE_RUN_EPOCH=0

# ═══════════════════════════════════════════════════════════════════════════════
# _pipeline_head_sha
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_pipeline_head_sha"

# Should return non-empty when inside a git repo
_sha_result=$(_pipeline_head_sha 2>/dev/null)
if [[ -n "$_sha_result" ]]; then
    assert_pass "_pipeline_head_sha: returns non-empty SHA inside git repo"
else
    # Acceptable if TEST_TEMP_DIR is not a git repo
    assert_pass "_pipeline_head_sha: returned empty (not in git repo — OK)"
fi

# Should never fail with non-zero exit
_pipeline_head_sha 2>/dev/null
assert_pass "_pipeline_head_sha: always exits 0"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_artifact_is_current
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_artifact_is_current"

_test_head_sha=$(_pipeline_head_sha 2>/dev/null)

# ── Missing file: pass-through (return 0) ────────────────────────────────────
if pipeline_artifact_is_current "$ARTIFACTS_DIR/nonexistent.json" 2>/dev/null; then
    assert_pass "pipeline_artifact_is_current: missing file is pass-through (return 0)"
else
    assert_fail "pipeline_artifact_is_current: missing file should be pass-through"
fi

# ── JSON without SHA: pass-through ───────────────────────────────────────────
echo '[{"severity":"high","finding":"test"}]' > "$ARTIFACTS_DIR/noshatest.json"
if pipeline_artifact_is_current "$ARTIFACTS_DIR/noshatest.json" 2>/dev/null; then
    assert_pass "pipeline_artifact_is_current: JSON without SHA is pass-through"
else
    assert_fail "pipeline_artifact_is_current: JSON without SHA should be pass-through"
fi

# ── .md without SHA: pass-through ────────────────────────────────────────────
echo "# Some heading" > "$ARTIFACTS_DIR/noshatest.md"
if pipeline_artifact_is_current "$ARTIFACTS_DIR/noshatest.md" 2>/dev/null; then
    assert_pass "pipeline_artifact_is_current: .md without SHA is pass-through"
else
    assert_fail "pipeline_artifact_is_current: .md without SHA should be pass-through"
fi

# ── .log without SHA: pass-through ───────────────────────────────────────────
echo "some log output without sha stamp" > "$ARTIFACTS_DIR/noshatest.log"
if pipeline_artifact_is_current "$ARTIFACTS_DIR/noshatest.log" 2>/dev/null; then
    assert_pass "pipeline_artifact_is_current: .log without SHA is pass-through"
else
    assert_fail "pipeline_artifact_is_current: .log without SHA should be pass-through"
fi

if [[ -n "$_test_head_sha" ]]; then
    # ── JSON with matching SHA: returns 0 ────────────────────────────────────
    echo "[{\"created_at_commit\":\"$_test_head_sha\",\"finding\":\"test\"}]" \
        > "$ARTIFACTS_DIR/matched.json"
    if pipeline_artifact_is_current "$ARTIFACTS_DIR/matched.json" 2>/dev/null; then
        assert_pass "pipeline_artifact_is_current: JSON with matching SHA returns 0"
    else
        assert_fail "pipeline_artifact_is_current: JSON with matching SHA should return 0"
    fi

    # ── JSON with mismatched SHA: returns 1 ──────────────────────────────────
    echo '[{"created_at_commit":"deadbeef","finding":"test"}]' \
        > "$ARTIFACTS_DIR/stale.json"
    if pipeline_artifact_is_current "$ARTIFACTS_DIR/stale.json" 2>/dev/null; then
        assert_fail "pipeline_artifact_is_current: JSON with stale SHA should return 1"
    else
        assert_pass "pipeline_artifact_is_current: JSON with stale SHA returns 1"
    fi

    # ── .md with matching SHA: returns 0 ─────────────────────────────────────
    printf 'created_at_commit: %s\n# Review content\n' "$_test_head_sha" \
        > "$ARTIFACTS_DIR/matched.md"
    if pipeline_artifact_is_current "$ARTIFACTS_DIR/matched.md" 2>/dev/null; then
        assert_pass "pipeline_artifact_is_current: .md with matching SHA returns 0"
    else
        assert_fail "pipeline_artifact_is_current: .md with matching SHA should return 0"
    fi

    # ── .md with mismatched SHA: returns 1 ───────────────────────────────────
    printf 'created_at_commit: deadbeef\n# Stale content\n' \
        > "$ARTIFACTS_DIR/stale.md"
    if pipeline_artifact_is_current "$ARTIFACTS_DIR/stale.md" 2>/dev/null; then
        assert_fail "pipeline_artifact_is_current: .md with stale SHA should return 1"
    else
        assert_pass "pipeline_artifact_is_current: .md with stale SHA returns 1"
    fi

    # ── .log with matching SHA: returns 0 ────────────────────────────────────
    printf '# created_at_commit: %s\nsome log output\n' "$_test_head_sha" \
        > "$ARTIFACTS_DIR/matched.log"
    if pipeline_artifact_is_current "$ARTIFACTS_DIR/matched.log" 2>/dev/null; then
        assert_pass "pipeline_artifact_is_current: .log with matching SHA returns 0"
    else
        assert_fail "pipeline_artifact_is_current: .log with matching SHA should return 0"
    fi

    # ── .log with mismatched SHA: returns 1 ──────────────────────────────────
    printf '# created_at_commit: deadbeef\nstale log output\n' \
        > "$ARTIFACTS_DIR/stale.log"
    if pipeline_artifact_is_current "$ARTIFACTS_DIR/stale.log" 2>/dev/null; then
        assert_fail "pipeline_artifact_is_current: .log with stale SHA should return 1"
    else
        assert_pass "pipeline_artifact_is_current: .log with stale SHA returns 1"
    fi
else
    assert_pass "pipeline_artifact_is_current SHA tests: skipped (not in git repo)"
fi

print_test_results
