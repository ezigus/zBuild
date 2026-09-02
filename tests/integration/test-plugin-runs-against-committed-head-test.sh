#!/usr/bin/env bash
# Integration: test plugin runs against the committed HEAD (post-Wave 12-C #662).
#
# Wave 12-B (#667) made diff.patch the cumulative branch delta since the
# intake baseline. After per-iter commits (#608), the actual work is already
# committed to HEAD; rsync brings it to the tmpdir. The historic
# `git apply --check diff.patch` + `git apply` block at
# plugins/tool/test/plugin.sh:141-158 was vestigial transport — worse, with
# cumulative diff.patch it tries to dup-apply commits already in HEAD.
#
# Wave 12-C removes the apply block entirely. This test pins the new contract:
#   1. tests run against the rsync'd HEAD (post-#608 committed state)
#   2. NO `git apply` is attempted (no `diff_apply_failed` verdict path)
#   3. test-results.json reflects actual test runner output
#   4. a non-empty diff.patch whose contents are ALREADY in HEAD does NOT
#      produce a dup-apply failure (the pre-12-C bug)
#
# RED-first: on pre-12-C plugin.sh, scenario 4 fails with
# verdict=error reason=diff_apply_failed because `git apply --check` rejects
# a patch whose changes already exist in HEAD.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test plugin runs against committed HEAD (Wave 12-C #662)"
setup_test_env "test-plugin-runs-against-committed-head"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# Real git repo with a baseline commit and a follow-up "iter-1" commit
# simulating post-#608 committed work.
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" -c user.name=t -c user.email=t@t \
    commit --allow-empty -m baseline -q

# Capture the baseline ref BEFORE the iter-1 commit (this mirrors what
# intake records at state_dir/intake-baseline-ref.txt and what Wave 12-B
# uses to compute the cumulative diff).
BASELINE_SHA="$(git -C "$REPO_FIXTURE" rev-parse HEAD)"

# Iter-1 commit: add a file. This is the work that the build stage committed
# per Wave 1 #608. After this, HEAD contains the iter-1 work.
printf 'iter-1 added line\n' > "$REPO_FIXTURE/iter1.txt"
git -C "$REPO_FIXTURE" add iter1.txt
git -C "$REPO_FIXTURE" -c user.name=t -c user.email=t@t \
    commit -m "iter-1 work" -q

# Build the cumulative diff.patch the same way Wave 12-B build does:
# `git diff $BASELINE_SHA..HEAD`. This patch describes work that IS ALREADY
# in HEAD. Pre-12-C, the test plugin would `git apply --check` this against
# a tree that already contains the changes and fail.
CUMULATIVE_PATCH="$ARTIFACT_DIR/diff.patch"
git -C "$REPO_FIXTURE" diff "$BASELINE_SHA..HEAD" > "$CUMULATIVE_PATCH"
[[ -s "$CUMULATIVE_PATCH" ]] || { printf 'fixture broken: cumulative diff is empty\n' >&2; exit 1; }

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# ─── Scenario A: tests run against committed HEAD; verdict=pass ──────────
print_test_section "1. tests run against committed HEAD (no apply)"

# Marker proves the test_cmd actually executed inside the rsync'd tmpdir
# (and saw the iter-1 commit's file, post-rsync).
MARKER="ZBUILD_W12C_MARKER_$RANDOM"
OUT_JSON_A="$ARTIFACT_DIR/results-committed-head.json"
STDERR_LOG_A="$TEST_TEMP_DIR/run-a.stderr"

# test_cmd checks for the iter-1 file (proves rsync brought committed HEAD),
# emits the marker, and reports a parseable pass count.
TEST_CMD_A="test -f iter1.txt && printf '%s\\n' '$MARKER' && printf '%s\\n' 'Tests:       0 failed, 1 passed, 1 total'"

_test_run_inner "$CUMULATIVE_PATCH" "$REPO_FIXTURE" "$OUT_JSON_A" "$TEST_CMD_A" \
    >/dev/null 2>"$STDERR_LOG_A" || true

assert_file_exists "test-results.json written" "$OUT_JSON_A"

# Core contract: verdict is NOT diff_apply_failed (the pre-12-C dup-apply bug).
REASON_A="$(jq -r '.reason // empty' "$OUT_JSON_A" 2>/dev/null)"
if [[ "$REASON_A" == "diff_apply_failed" ]]; then
    assert_fail "no diff_apply_failed verdict (W12-C contract)" \
        "got reason=$REASON_A; cumulative diff was dup-applied against HEAD"
else
    assert_pass "no diff_apply_failed verdict (reason='$REASON_A')"
fi

# verdict=pass derived from the test_cmd's parseable output — proves the
# parser ran on real test runner output, not the apply-error path.
assert_eq "verdict=pass from parsed test_cmd output" "pass" \
    "$(jq -r '.verdict' "$OUT_JSON_A" 2>/dev/null)"

# Marker present in test_output proves the test_cmd actually executed
# (not short-circuited by an apply check).
TEST_OUT_A="$(jq -r '.data.test_output' "$OUT_JSON_A" 2>/dev/null)"
if [[ "$TEST_OUT_A" == *"$MARKER"* ]]; then
    assert_pass "test_cmd executed against rsync'd HEAD (marker present)"
else
    assert_fail "test_cmd executed against rsync'd HEAD" \
        "marker '$MARKER' missing from .test_output: $TEST_OUT_A"
fi

# exit_code is numeric (no string-label regression — #625 invariant survives).
EC_A="$(jq -r '.data.exit_code' "$OUT_JSON_A" 2>/dev/null)"
if [[ "$EC_A" =~ ^[0-9]+$ ]]; then
    assert_pass ".exit_code is numeric ($EC_A)"
else
    assert_fail ".exit_code is numeric" "got: $EC_A"
fi

# ─── Scenario B: source tree does NOT call `git apply` on diff.patch ─────
print_test_section "2. plugin.sh source has no git apply on diff.patch"

# Static contract: the plugin source must not contain executable `git apply`
# referencing diff.patch — Wave 12-C deletes the apply block entirely. This
# guards against re-introduction in future edits. Comment-only mentions
# (audit trail of the removal) are explicitly allowed.
PLUGIN_SRC="$REPO_ROOT/plugins/tool/test/plugin.sh"
# Strip comments + blank lines, then grep for `git apply` invocations.
_NONCOMMENT="$(grep -vE '^[[:space:]]*(#|$)' "$PLUGIN_SRC")"
if printf '%s\n' "$_NONCOMMENT" | grep -E 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?apply\b' >/dev/null 2>&1; then
    assert_fail "plugin.sh contains no 'git apply' call (non-comment)" \
        "found: $(printf '%s\n' "$_NONCOMMENT" | grep -nE 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?apply\b' | head -3)"
else
    assert_pass "plugin.sh contains no 'git apply' call (non-comment)"
fi

if printf '%s\n' "$_NONCOMMENT" | grep -F 'diff_apply_failed' >/dev/null 2>&1; then
    assert_fail "plugin.sh has no diff_apply_failed verdict path (non-comment)" \
        "found: $(printf '%s\n' "$_NONCOMMENT" | grep -nF 'diff_apply_failed' | head -3)"
else
    assert_pass "plugin.sh has no diff_apply_failed verdict path (non-comment)"
fi

# ─── Scenario C: manifest does not declare diff_patch input ──────────────
print_test_section "3. manifest.yaml removes diff_patch input declaration"

MANIFEST="$REPO_ROOT/plugins/tool/test/manifest.yaml"
if grep -E '^[[:space:]]*-?[[:space:]]*id:[[:space:]]*diff_patch' "$MANIFEST" >/dev/null 2>&1; then
    assert_fail "manifest.yaml has no diff_patch input declaration" \
        "found diff_patch id in $MANIFEST"
else
    assert_pass "manifest.yaml has no diff_patch input declaration"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
