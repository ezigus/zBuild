#!/usr/bin/env bash
# Tests: plugins/tool/test/plugin.sh — empty diff.patch must run the test
# command against the rsync'd HEAD (#625 → #662 / Wave 12-C).
#
# Background: post-#608 the build commits each iter to HEAD. Wave 10A (#625)
# added a `[[ -s "$diff_patch_path" ]]` guard so empty patches skipped the
# `git apply --check` step. Wave 12-C (#662) removed the apply block entirely
# — test now ALWAYS runs against the rsync'd HEAD regardless of diff.patch
# size. This test pins the contract that an empty diff.patch produces a real
# parsed verdict (not the historic apply-failure verdict).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-plugin empty-diff.patch guard (#625 / #608)"

setup_test_env "test-plugin-empty-diff"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" -c user.name=t -c user.email=t@t \
    commit --allow-empty -m init -q

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# ─── 1. zero-byte diff.patch: test command runs, output captured ────────────
print_test_section "1. zero-byte diff.patch → test command runs"

EMPTY_PATCH="$ARTIFACT_DIR/diff.patch"
: > "$EMPTY_PATCH"

OUT_JSON="$ARTIFACT_DIR/results-empty.json"
STDERR_LOG="$TEST_TEMP_DIR/run.stderr"

# Distinctive marker so we can prove the test command actually executed.
MARKER="ZBUILD_625_MARKER_$RANDOM"
TEST_CMD="printf '%s\\n%s\\n' '$MARKER' 'Tests:       0 failed, 3 passed, 3 total'; exit 0"

_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$OUT_JSON" "$TEST_CMD" \
    >/dev/null 2>"$STDERR_LOG" || true

assert_file_exists "empty-diff: test-results.json written" "$OUT_JSON"

# Verdict must NOT be diff_apply_failed — should be pass (or at minimum a
# verdict produced by parsing the test command output, not the apply-error
# path).
APPLY_REASON="$(jq -r '.reason // empty' "$OUT_JSON" 2>/dev/null)"
if [[ "$APPLY_REASON" == "diff_apply_failed" ]]; then
    assert_fail "empty-diff: skips apply-check (no diff_apply_failed)" \
        "got reason=$APPLY_REASON; empty diff was treated as a failed apply"
else
    assert_pass "empty-diff: skips apply-check (reason='$APPLY_REASON')"
fi

# Test command output must appear in .data.test_output — proves it ran.
TEST_OUT="$(jq -r '.data.test_output' "$OUT_JSON" 2>/dev/null)"
if [[ "$TEST_OUT" == *"$MARKER"* ]]; then
    assert_pass "empty-diff: test command was executed (marker present)"
else
    assert_fail "empty-diff: test command was executed" \
        "marker '$MARKER' missing from .data.test_output: $TEST_OUT"
fi

# exit_code numeric + verdict=pass (3 passed, 0 failed → pass per parser).
EC="$(jq -r '.data.exit_code' "$OUT_JSON" 2>/dev/null)"
if [[ "$EC" =~ ^[0-9]+$ ]]; then
    assert_pass "empty-diff: .data.exit_code is numeric ($EC)"
else
    assert_fail "empty-diff: .data.exit_code is numeric" "got: $EC"
fi

assert_eq "empty-diff: verdict=pass" "pass" \
    "$(jq -r '.verdict' "$OUT_JSON" 2>/dev/null)"

# ─── 2. zero-byte diff.patch: failing test rc is captured ───────────────────
print_test_section "2. zero-byte diff.patch + failing tests → rc captured"

OUT_FAIL_JSON="$ARTIFACT_DIR/results-empty-fail.json"
FAIL_CMD="printf '%s\\n' 'Tests:       2 failed, 1 passed, 3 total'; exit 1"
_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$OUT_FAIL_JSON" "$FAIL_CMD" \
    >/dev/null 2>&1 || true

assert_eq "empty-diff fail: verdict=fail" "fail" \
    "$(jq -r '.verdict' "$OUT_FAIL_JSON" 2>/dev/null)"
assert_eq "empty-diff fail: data.exit_code=1" "1" \
    "$(jq -r '.data.exit_code' "$OUT_FAIL_JSON" 2>/dev/null)"

print_test_results
exit $((FAIL > 0))
