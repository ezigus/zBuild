#!/usr/bin/env bash
# Tests: plugins/tool/test/plugin.sh — _test_write_result positional-arg
# correctness across every caller (#625).
#
# Root cause from dogfood run 20260601185344-237: the apply-failure path
# passed the literal string "diff_apply_failed" into slot 3 (exit_code),
# crashing jq with "invalid JSON" because --argjson expects numeric/null.
# Function signature is:
#   path, verdict, exit_code, passed, failed, test_output, diff_applied,
#   test_cmd, [reason]
#
# This test drives every _test_write_result caller path and asserts:
#   1. jq does not crash (no "invalid JSON" on stderr)
#   2. test-results.json is written and parseable
#   3. .exit_code is numeric (never a string label)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-plugin _test_write_result positional args (#625)"

setup_test_env "test-plugin-positional-args"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# Tiny git repo
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" -c user.name=t -c user.email=t@t \
    commit --allow-empty -m init -q

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# ─── 1. apply-failure path produces numeric exit_code (the dogfood crash) ────
print_test_section "1. apply-failure path: numeric exit_code, no jq crash"

# Create a non-empty diff that won't apply (references a missing file).
BAD_PATCH="$ARTIFACT_DIR/diff-bad.patch"
cat > "$BAD_PATCH" <<'PATCH'
diff --git a/does-not-exist.txt b/does-not-exist.txt
index 0000000..1111111 100644
--- a/does-not-exist.txt
+++ b/does-not-exist.txt
@@ -1 +1 @@
-old
+new
PATCH

APPLY_FAIL_JSON="$ARTIFACT_DIR/results-apply-fail.json"
APPLY_FAIL_STDERR="$TEST_TEMP_DIR/apply-fail.stderr"
_test_run_inner "$BAD_PATCH" "$REPO_FIXTURE" "$APPLY_FAIL_JSON" "true" \
    >/dev/null 2>"$APPLY_FAIL_STDERR" || true

assert_file_exists "apply-fail: test-results.json written" "$APPLY_FAIL_JSON"

# jq must not have crashed with "invalid JSON" / "Could not open file" / etc.
if grep -qiE 'invalid (numeric literal|json|input)|jq: error' "$APPLY_FAIL_STDERR"; then
    assert_fail "apply-fail: jq did not crash" \
        "stderr contains jq error: $(cat "$APPLY_FAIL_STDERR")"
else
    assert_pass "apply-fail: jq did not crash"
fi

# .exit_code must be numeric (the bug put a string here)
APPLY_FAIL_EC="$(jq -r '.exit_code' "$APPLY_FAIL_JSON" 2>/dev/null || echo PARSE_FAIL)"
if [[ "$APPLY_FAIL_EC" =~ ^[0-9]+$ ]]; then
    assert_pass "apply-fail: .exit_code is numeric ($APPLY_FAIL_EC)"
else
    assert_fail "apply-fail: .exit_code is numeric" \
        "got: $APPLY_FAIL_EC"
fi

# Verdict should be error; reason should surface diff_apply_failed
assert_eq "apply-fail: verdict=error" "error" \
    "$(jq -r '.verdict' "$APPLY_FAIL_JSON" 2>/dev/null)"
assert_eq "apply-fail: reason=diff_apply_failed" "diff_apply_failed" \
    "$(jq -r '.reason // empty' "$APPLY_FAIL_JSON" 2>/dev/null)"

# ─── 2. missing-diff path: numeric exit_code, no jq crash ───────────────────
print_test_section "2. missing-diff path: numeric exit_code, no jq crash"

MISSING_JSON="$ARTIFACT_DIR/results-missing.json"
MISSING_STDERR="$TEST_TEMP_DIR/missing.stderr"
NONEXISTENT_PATCH="$TEST_TEMP_DIR/does-not-exist.patch"
_test_run_inner "$NONEXISTENT_PATCH" "$REPO_FIXTURE" "$MISSING_JSON" "true" \
    >/dev/null 2>"$MISSING_STDERR" || true

assert_file_exists "missing-diff: test-results.json written" "$MISSING_JSON"

if grep -qiE 'invalid (numeric literal|json|input)|jq: error' "$MISSING_STDERR"; then
    assert_fail "missing-diff: jq did not crash" \
        "stderr: $(cat "$MISSING_STDERR")"
else
    assert_pass "missing-diff: jq did not crash"
fi

MISSING_EC="$(jq -r '.exit_code' "$MISSING_JSON" 2>/dev/null || echo PARSE_FAIL)"
if [[ "$MISSING_EC" =~ ^[0-9]+$ ]]; then
    assert_pass "missing-diff: .exit_code is numeric ($MISSING_EC)"
else
    assert_fail "missing-diff: .exit_code is numeric" "got: $MISSING_EC"
fi

# ─── 3. happy path (terminal write): numeric exit_code, no crash ────────────
print_test_section "3. happy path: numeric exit_code, no jq crash"

EMPTY_PATCH="$ARTIFACT_DIR/diff-empty.patch"
: > "$EMPTY_PATCH"

HAPPY_JSON="$ARTIFACT_DIR/results-happy.json"
HAPPY_STDERR="$TEST_TEMP_DIR/happy.stderr"
HAPPY_CMD=$'printf "%s\\n" "Tests:       0 failed, 5 passed, 5 total"; exit 0'
_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$HAPPY_JSON" "$HAPPY_CMD" \
    >/dev/null 2>"$HAPPY_STDERR" || true

assert_file_exists "happy: test-results.json written" "$HAPPY_JSON"

if grep -qiE 'invalid (numeric literal|json|input)|jq: error' "$HAPPY_STDERR"; then
    assert_fail "happy: jq did not crash" \
        "stderr: $(cat "$HAPPY_STDERR")"
else
    assert_pass "happy: jq did not crash"
fi

HAPPY_EC="$(jq -r '.exit_code' "$HAPPY_JSON" 2>/dev/null || echo PARSE_FAIL)"
if [[ "$HAPPY_EC" =~ ^[0-9]+$ ]]; then
    assert_pass "happy: .exit_code is numeric ($HAPPY_EC)"
else
    assert_fail "happy: .exit_code is numeric" "got: $HAPPY_EC"
fi

print_test_results
exit $((FAIL > 0))
