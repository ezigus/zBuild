#!/usr/bin/env bash
# Integration: _test_run_inner leaves no zbuild-test-stage.* tmpdir behind on
# any exit path (#628).
#
# Three previously-distinct exit paths each used to require its own manual
# `rm -rf "$tmp"`; the apply-failure path added in #625 leaked outright
# (annotated inline as "tmpdir cleanup: addressed by RETURN trap in #628").
# This test forces _test_run_inner down each path and asserts the staging
# directory is gone afterward.
#
# RED-first: ran against pre-#628 plugin.sh, the apply-failure case leaves
# a `zbuild-test-stage.*` dir behind in $TMPDIR.
#
# #1829 (ADR-054 §7): the RETURN trap now kills the eval subshell PID instead of
# rm -rf-ing the staging dir. Purge is now explicit via test_cleanup(purge).
# This test calls test_cleanup("test", state_file, "purge") after each
# _test_run_inner to match the lifecycle-correct path; the no-leak assertions are
# unchanged and still pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: _test_run_inner tmpdir self-cleanup (#628)"
setup_test_env "test-plugin-tmpdir-cleanup"

# Isolated event bus
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Pin TMPDIR so we know exactly where to look for leaks.
ISOLATED_TMP="$TEST_TEMP_DIR/iso-tmp"
mkdir -p "$ISOLATED_TMP"
export TMPDIR="$ISOLATED_TMP"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"
ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# Minimal state file so test_cleanup can derive artifact_dir (#1829).
_STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
printf '{}' > "$_STATE_FILE"

# Real (tiny) git repo to act as the source the test stage rsync's from.
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" -c user.name=t -c user.email=t@t \
    commit --allow-empty -m init -q

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

_count_leaked() {
    # Count zbuild-test-stage.* dirs surviving in $TMPDIR.
    local n=0
    for d in "$TMPDIR"/zbuild-test-stage.*; do
        [[ -e "$d" ]] || continue
        n=$(( n + 1 ))
    done
    printf '%s' "$n"
}

# ───────────────────────────────────────────────────────────────────────────
print_test_section "1. missing diff.patch (early-return guard)"
# ───────────────────────────────────────────────────────────────────────────

MISSING_PATCH="$ARTIFACT_DIR/does-not-exist.patch"
JSON1="$ARTIFACT_DIR/test-results-missing.json"
_test_run_inner "$MISSING_PATCH" "$REPO_FIXTURE" "$JSON1" "true" \
    >/dev/null 2>&1 || true
# #1829: explicit purge via lifecycle-correct cleanup hook (RETURN trap no
# longer rm -rf's; purge is the cleanup hook's responsibility).
test_cleanup "test" "$_STATE_FILE" "purge" >/dev/null 2>&1 || true

assert_eq "missing-diff: artifact still written" \
    "error" "$(jq -r '.verdict' "$JSON1" 2>/dev/null || echo MISSING)"
assert_eq "missing-diff: no zbuild-test-stage.* leaked in TMPDIR" \
    "0" "$(_count_leaked)"

# ───────────────────────────────────────────────────────────────────────────
print_test_section "2. non-empty diff.patch path (W12-C: diff ignored, tmpdir still cleaned)"
# ───────────────────────────────────────────────────────────────────────────

# Wave 12-C (#662) removed the apply path; a non-empty diff.patch no longer
# triggers a distinct exit branch. We still exercise the non-empty-diff input
# slot to confirm the RETURN trap fires on the normal completion path even when
# a (now-ignored) bad patch is supplied.
BAD_PATCH="$ARTIFACT_DIR/diff.patch"
cat > "$BAD_PATCH" <<'PATCH'
diff --git a/no-such-file.txt b/no-such-file.txt
index 0000001..0000002 100644
--- a/no-such-file.txt
+++ b/no-such-file.txt
@@ -1,1 +1,1 @@
-original line that does not exist
+new line
PATCH

JSON2="$ARTIFACT_DIR/test-results-apply-fail.json"
# Use a parseable passing test_cmd so the parsed-verdict path is exercised.
_test_run_inner "$BAD_PATCH" "$REPO_FIXTURE" "$JSON2" \
    $'printf \'%s\\n\' "Tests:       0 failed, 1 passed, 1 total"; exit 0' \
    >/dev/null 2>&1 || true
# #1829: explicit purge to clean staging dir.
test_cleanup "test" "$_STATE_FILE" "purge" >/dev/null 2>&1 || true

assert_eq "non-empty-diff: verdict=pass (diff ignored, test_cmd parsed)" \
    "pass" "$(jq -r '.verdict' "$JSON2" 2>/dev/null || echo MISSING)"
NON_EMPTY_REASON="$(jq -r '.reason // empty' "$JSON2" 2>/dev/null)"
if [[ "$NON_EMPTY_REASON" == "diff_apply_failed" ]]; then
    assert_fail "non-empty-diff: no diff_apply_failed reason (W12-C)" \
        "got: $NON_EMPTY_REASON"
else
    assert_pass "non-empty-diff: no diff_apply_failed reason (reason='$NON_EMPTY_REASON')"
fi
assert_eq "non-empty-diff: no zbuild-test-stage.* leaked in TMPDIR" \
    "0" "$(_count_leaked)"

# ───────────────────────────────────────────────────────────────────────────
print_test_section "3. success path (empty diff + trivial passing cmd)"
# ───────────────────────────────────────────────────────────────────────────

EMPTY_PATCH="$ARTIFACT_DIR/diff.patch"
: > "$EMPTY_PATCH"
JSON3="$ARTIFACT_DIR/test-results-ok.json"
# Print a recognizable pattern-bank line so parser flags verdict=pass and
# we don't get tripped by the #485 silent-failure guard.
PASS_CMD='printf "%s\n" "Tests: 1 passed, 0 failed, 1 total"; exit 0'
_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$JSON3" "$PASS_CMD" \
    >/dev/null 2>&1 || true
# #1829: explicit purge to clean staging dir.
test_cleanup "test" "$_STATE_FILE" "purge" >/dev/null 2>&1 || true

assert_eq "success: artifact written" \
    "0" "$(jq -r '.exit_code' "$JSON3" 2>/dev/null || echo MISSING)"
assert_eq "success: no zbuild-test-stage.* leaked in TMPDIR" \
    "0" "$(_count_leaked)"

# ───────────────────────────────────────────────────────────────────────────
print_test_section "4. [SPEC-5] test_cleanup(purge) is the lifecycle-correct rm-rf path"
# ───────────────────────────────────────────────────────────────────────────
# At baseline (pre-#1829) test_cleanup did not exist; the RETURN trap did
# rm -rf. Post-#1829: RETURN trap only kills PGID; purge is test_cleanup's
# responsibility. This assertion fails at baseline because test_cleanup is new.

SPEC5_STAGING="$ISOLATED_TMP/spec5-staging"
mkdir -p "$SPEC5_STAGING"
printf 'sentinel' > "$SPEC5_STAGING/sentinel.txt"
# Write the staging path so test_cleanup(purge) can find it.
printf '%s' "$SPEC5_STAGING" > "$ARTIFACT_DIR/.test-staging-path"

test_cleanup "test" "$_STATE_FILE" "purge" >/dev/null 2>&1 || true

if [[ -d "$SPEC5_STAGING" ]]; then
    assert_fail "[SPEC-5] test_cleanup(purge) removes the staging directory" \
        "dir still exists after purge"
else
    assert_pass "[SPEC-5] test_cleanup(purge) removes the staging directory"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
