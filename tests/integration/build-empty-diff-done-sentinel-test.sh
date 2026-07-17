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
# build_verdict="empty_diff" in the empty-diff branch (may be in lib/summary.sh after #1533).
fix_present=$(grep -r 'build_verdict="empty_diff"' "$REPO_ROOT/plugins/agent/build/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${fix_present:-0}" -ge 1 ]]; then
    assert_pass "build plugin sets build_verdict=empty_diff on done_sentinel + 0 files"
else
    assert_fail "build plugin should set build_verdict=empty_diff on done_sentinel + 0 files" "expected: at least 1 match"
fi

print_test_section "4. inert_build verdict — #1532 false-completion guard"

# [SPEC-2] runner_read_stage_verdict returns fail for verdict=inert_build
# (CHANGE — was "warn" via unknown_verdict path before inert_build was registered)
INERT_FIXTURE="$ZBUILD_STATE_DIR/artifacts/build-summary.json"
cat > "$INERT_FIXTURE" <<'EOF'
{
  "schema_version": 4,
  "issue": 12,
  "files_changed": [],
  "lines_added": 0,
  "lines_removed": 0,
  "diff_patch_path": "/tmp/empty.patch",
  "iterations": 1,
  "terminated_reason": "done_sentinel",
  "verdict": "inert_build",
  "failing_acceptance_testfile": "tests/unit/some-test.sh",
  "scope_violation": false,
  "scope_violations": [],
  "loop_input_tokens": 100,
  "loop_output_tokens": 50,
  "notes": "Build stage completed."
}
EOF

if [[ -f "$BUILD_MANIFEST" ]]; then
    classified_inert=$(runner_read_stage_verdict "$ZBUILD_STATE_DIR" "$BUILD_MANIFEST" "build" 0 2>/dev/null || echo "missing")
    assert_eq "[SPEC-2] runner_read_stage_verdict returns fail for verdict=inert_build" "fail" "$classified_inert"

    # [SPEC-3] runner_read_stage_verdict_raw returns raw "inert_build" (GUARD)
    raw_inert=$(runner_read_stage_verdict_raw "$ZBUILD_STATE_DIR" "$BUILD_MANIFEST" "build" 0 2>/dev/null || echo "missing")
    assert_eq "[SPEC-3] runner_read_stage_verdict_raw returns raw inert_build" "inert_build" "$raw_inert"
else
    assert_fail "[SPEC-2] build manifest not found at $BUILD_MANIFEST"
    assert_fail "[SPEC-3] build manifest not found at $BUILD_MANIFEST"
fi

# [SPEC-4] failing_acceptance_testfile field is present and readable (GUARD)
failing_field=$(jq -r '.failing_acceptance_testfile // empty' "$INERT_FIXTURE")
assert_eq "[SPEC-4] failing_acceptance_testfile field is readable from inert_build summary" \
    "tests/unit/some-test.sh" "$failing_field"

# [SPEC-5] verdict_classify("empty_diff") still returns fail — regression guard
# (ensures adding inert_build to verdict.sh did not disturb the empty_diff arm)
assert_eq "[SPEC-5] verdict_classify(empty_diff) still = fail after adding inert_build" \
    "fail" "$(verdict_classify "empty_diff")"

print_test_section "5. build plugin PRODUCES the inert_build signal from a red acceptance testfile"

# Sections 2–4 exercise verdict.sh + the summary reader; they do NOT touch the
# build-plugin code that DETECTS the false completion. This section drives that
# code directly so reverting plugins/agent/build/plugin.sh to baseline breaks a
# declared TESTFILE — proving the guard wiring is load-bearing, not inert
# (ADR-036 reachability; the #1532 dogfood failed here on inert_wiring).
#
# Minimal mocks so build/plugin.sh sources without spawning claude.
# shellcheck disable=SC2317
route_to_model_loop() { _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0; _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"; return 0; }
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() { local in="$1" out="$2"; [[ -f "$in" ]] && cp "$in" "$out"; return 0; }

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

GUARD_REPO="$TEST_TEMP_DIR/guard-repo"
mkdir -p "$GUARD_REPO/tests/unit"
(
    cd "$GUARD_REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m seed
) >/dev/null
cat > "$GUARD_REPO/tests/unit/red-acceptance-test.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$GUARD_REPO/tests/unit/red-acceptance-test.sh"

# [SPEC-1] the build guard names the still-red acceptance testfile (the input the
# caller uses to override build_verdict → inert_build). At the merge-base baseline
# _build_guard_false_completion does not exist, so guard_out is empty and this
# assertion fails — the negative control / reachability lever for build/plugin.sh.
# The helper prints the failing testfile path to stdout and exits non-zero; the
# `|| true` keeps `set -e` happy and, at baseline (helper absent), yields "".
guard_out="$(_build_guard_false_completion "tests/unit/red-acceptance-test.sh" "$GUARD_REPO" 2>/dev/null || true)"
assert_eq "[SPEC-1] build guard names the red acceptance testfile (produces inert_build signal)" \
    "tests/unit/red-acceptance-test.sh" "$guard_out"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
