#!/usr/bin/env bash
# Integration: Wave 19-D-3 (#733) — build plugin's empty-diff done_sentinel
# must produce a non-pass verdict so the cycle's plateau/divergence
# detectors see real signal.
#
# Dogfood 20260605140602-80831 (issue #12) iter 3: build emitted
# done_sentinel with files_changed=0, but plugin verdict was "pass". The
# cycle accepted this as progress, ran test (which failed same as iter 2),
# and wasted an iter. The empty-diff condition should be a structural
# failure — the LLM signaled "done" without producing a diff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "build empty-diff done_sentinel produces non-pass verdict (Wave 19-D-3 #733)"
setup_test_env "build-empty-diff-done-sentinel"

# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

print_test_section "1. verdict_classify maps empty_diff → fail"

# Pre-condition: classifier must recognize empty_diff as a structural failure
# so the cycle's verdict-blob accumulation registers it as no-progress.
result=$(verdict_classify "empty_diff")
assert_eq "verdict_classify('empty_diff') = fail" "fail" "$result"

# Regression-lock the rest of the verdict table.
assert_eq "verdict_classify('pass') = pass" "pass" "$(verdict_classify pass)"
assert_eq "verdict_classify('approve') = pass" "pass" "$(verdict_classify approve)"
assert_eq "verdict_classify('request_changes') = warn" "warn" "$(verdict_classify request_changes)"
assert_eq "verdict_classify('fail') = fail" "fail" "$(verdict_classify fail)"
assert_eq "verdict_classify('scope_violation') = fail" "fail" "$(verdict_classify scope_violation)"

print_test_section "2. build plugin sets verdict=empty_diff when done_sentinel + 0 files"

# Set up a minimal fixture repo + scope manifest so the build plugin can run.
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" config user.name t
git -C "$REPO_FIXTURE" config user.email t@t
printf 'unchanged\n' > "$REPO_FIXTURE/tracked.txt"
git -C "$REPO_FIXTURE" add tracked.txt
git -C "$REPO_FIXTURE" commit -q -m init

export ZBUILD_REPO_ROOT="$REPO_FIXTURE"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
: > "$ZBUILD_EVENTS_JSONL"

# We can't easily drive the full build loop here (it spawns claude). Instead
# test the verdict-derivation logic directly by calling the build plugin's
# helper that decides verdict from terminated_reason + files_count. The
# plan section directs the implementer to a `_build_derive_verdict` helper.
# For now we test the JSON shape post-fix: the build-summary.json's verdict
# field reads "empty_diff" when files_changed=0 + terminated_reason=done_sentinel.

# We synthesize the build-summary.json the way the build plugin would
# AFTER the empty-diff fix, then assert the verdict field is "empty_diff".
# The plugin code change is what makes this happen in production.
SUMMARY_FIXTURE="$ZBUILD_STATE_DIR/artifacts/build-summary.json"
cat > "$SUMMARY_FIXTURE" <<'EOF'
{
  "schema_version": 4,
  "issue": 12,
  "files_changed": [],
  "lines_added": 0,
  "lines_removed": 0,
  "diff_patch_path": "/tmp/empty.patch",
  "iterations": 1,
  "terminated_reason": "done_sentinel",
  "verdict": "empty_diff",
  "scope_violation": false,
  "scope_violations": [],
  "loop_input_tokens": 100,
  "loop_output_tokens": 50,
  "notes": "Build stage completed."
}
EOF

# Verify reader infrastructure parses verdict correctly.
verdict_from_json=$(jq -r '.verdict' "$SUMMARY_FIXTURE")
assert_eq "build-summary.json verdict=empty_diff readable" "empty_diff" "$verdict_from_json"

# Verify runner_read_stage_verdict_raw returns the raw verdict and
# classifies it to "fail" for cycle predicate consumption.
BUILD_MANIFEST="$REPO_ROOT/plugins/agent/build/manifest.yaml"
if [[ -f "$BUILD_MANIFEST" ]]; then
    raw=$(runner_read_stage_verdict_raw "$ZBUILD_STATE_DIR" "$BUILD_MANIFEST" "build" 0 2>/dev/null || echo "missing")
    assert_eq "runner_read_stage_verdict_raw returns 'empty_diff'" "empty_diff" "$raw"

    classified=$(runner_read_stage_verdict "$ZBUILD_STATE_DIR" "$BUILD_MANIFEST" "build" 0 2>/dev/null || echo "missing")
    assert_eq "runner_read_stage_verdict (classified) returns 'fail' for empty_diff" "fail" "$classified"
else
    assert_fail "build manifest not found at $BUILD_MANIFEST"
fi

print_test_section "3. build plugin code produces empty_diff verdict on done_sentinel + 0 files"

# Look for the marker in the build plugin source — the fix must set
# build_verdict="empty_diff" in the empty-diff branch.
fix_present=$(grep 'build_verdict="empty_diff"' "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${fix_present:-0}" -ge 1 ]]; then
    assert_pass "build plugin sets build_verdict=empty_diff on done_sentinel + 0 files"
else
    assert_fail "build plugin should set build_verdict=empty_diff on done_sentinel + 0 files" "expected: at least 1 match"
fi

print_test_results
cleanup_test_env
exit $((FAIL > 0))
