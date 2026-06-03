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

# ─── 1. non-empty diff.patch (W12-C: not applied) → numeric exit_code, no jq crash ────
# Wave 12-C (#662) removed the apply path; a non-empty diff.patch is no longer
# read by the test plugin. This section now pins the W12-C contract: the bad
# patch is IGNORED, the test_cmd runs against the rsync'd HEAD, and the
# writer produces a valid JSON artifact with numeric exit_code (the #625
# invariant survives the apply removal).
print_test_section "1. non-empty diff.patch ignored (W12-C): numeric exit_code, no jq crash"

# Create a non-empty diff that the pre-W12-C code would have failed to apply.
# Post-W12-C the file is not read; we just exercise the writer's numeric
# slot under a "real" parsed verdict.
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
# Parseable passing test_cmd so the parsed-verdict path is exercised.
_test_run_inner "$BAD_PATCH" "$REPO_FIXTURE" "$APPLY_FAIL_JSON" \
    $'printf \'%s\\n\' "Tests:       0 failed, 2 passed, 2 total"; exit 0' \
    >/dev/null 2>"$APPLY_FAIL_STDERR" || true

assert_file_exists "bad-patch: test-results.json written" "$APPLY_FAIL_JSON"

# jq must not have crashed with "invalid JSON" / "Could not open file" / etc.
if grep -qiE 'invalid (numeric literal|json|input)|jq: error' "$APPLY_FAIL_STDERR"; then
    assert_fail "bad-patch: jq did not crash" \
        "stderr contains jq error: $(cat "$APPLY_FAIL_STDERR")"
else
    assert_pass "bad-patch: jq did not crash"
fi

# .exit_code must be numeric (#625 invariant — sanitizer survives W12-C)
APPLY_FAIL_EC="$(jq -r '.exit_code' "$APPLY_FAIL_JSON" 2>/dev/null || echo PARSE_FAIL)"
if [[ "$APPLY_FAIL_EC" =~ ^[0-9]+$ ]]; then
    assert_pass "bad-patch: .exit_code is numeric ($APPLY_FAIL_EC)"
else
    assert_fail "bad-patch: .exit_code is numeric" \
        "got: $APPLY_FAIL_EC"
fi

# W12-C contract: diff.patch is NOT consulted; verdict comes from test_cmd
# output, NOT a synthetic apply-failure path.
assert_eq "bad-patch: verdict=pass (diff ignored, test_cmd parsed)" "pass" \
    "$(jq -r '.verdict' "$APPLY_FAIL_JSON" 2>/dev/null)"
APPLY_FAIL_REASON="$(jq -r '.reason // empty' "$APPLY_FAIL_JSON" 2>/dev/null)"
if [[ "$APPLY_FAIL_REASON" == "diff_apply_failed" ]]; then
    assert_fail "bad-patch: no diff_apply_failed verdict (W12-C)" \
        "got reason=$APPLY_FAIL_REASON; apply path should be gone"
else
    assert_pass "bad-patch: no diff_apply_failed verdict (reason='$APPLY_FAIL_REASON')"
fi

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
