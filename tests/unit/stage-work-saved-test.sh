#!/usr/bin/env bash
# Tests (#2187): every stage's work is saved and pushed when the stage ends, so a
# run killed mid-way (a 6-hour job ceiling, a SIGKILL) leaves its work on origin
# for the next session — not only what the end-of-run persist stage pushes.
#
# #1849 run 35949629759: test-author and acceptance-gate failed and were never
# snapshotted ("a failed member has nothing worth carrying"); the state branch
# and the work branch were pushed once each, at the end of the run.
#
# SPEC-1 [change]: a cycle member that FAILED is snapshotted too.
# SPEC-2 [change]: a run that declares where its work goes (ZBUILD_WORKSPACE_BRANCH,
#   as the CI pipeline sets it) pushes each stage-end snapshot to origin at once.
# SPEC-3 [change]: …and pushes the run's commits to that work branch.
# SPEC-4 [guard] : a run that declares no work branch (every test, a plain local
#   run) pushes nothing at a stage end — the persist stage still does at the end.
# SPEC-5 [change]: a snapshot whose artifacts look like they carry a credential is
#   not pushed (the persist stage's refusal, now on every push path).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "every stage's work is saved and pushed at the stage end (#2187)"
setup_test_env "stage-work-saved"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"

# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
set +e   # runner.sh turns errexit on; assertions must all run

_ID="$(zb_test_issue)"
REMOTE="$TEST_TEMP_DIR/remote.git"; REPO="$TEST_TEMP_DIR/repo"
git init -q --bare "$REMOTE"
mkdir -p "$REPO"
(
    cd "$REPO" || exit 1
    git init -q -b main .
    git config user.email t@e.st; git config user.name t
    git remote add origin "$REMOTE"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
) >/dev/null 2>&1
BASELINE="$(git -C "$REPO" rev-parse HEAD)"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE/artifacts"
printf '%s' "$BASELINE" > "$STATE/intake-baseline-ref.txt"
export ZBUILD_STATE_DIR="$STATE"
export ZBUILD_REPO_ROOT="$REPO"
_runner_issue="$_ID"
STATE_BRANCH="zbuild/state/issue-$_ID"

_on_origin() { git -C "$REPO" ls-remote --heads origin "refs/heads/$1" 2>/dev/null | awk '{print $1}'; }

# ─── SPEC-1/2: a FAILED member is snapshotted, and the snapshot is pushed ─────
print_test_section "SPEC-1/2: a failed member's work is snapshotted and pushed"
printf '{"verdict":"degraded","disposition":"interrupted"}\n' > "$STATE/artifacts/test-author-result.json"
( cd "$REPO" && ZBUILD_WORKSPACE_BRANCH="zbuild/issue-$_ID-ci" _CYCLE_TRAP_CYCLE_ID=c _CYCLE_TRAP_ITER=1 \
    _cycle_emit_member_dispatch_complete 1 "test-author" 1 "fail" "failed" ) >/dev/null 2>&1
assert_eq "[SPEC-1] the failed member's artifacts are on the local state branch" "1" \
    "$(git -C "$REPO" rev-parse -q --verify "refs/heads/$STATE_BRANCH" >/dev/null 2>&1 && echo 1 || echo 0)"
if [[ -n "$(_on_origin "$STATE_BRANCH")" ]]; then
    assert_pass "[SPEC-2] the state branch is on origin at the stage end"
else
    assert_fail "[SPEC-2] the state branch was not pushed at the stage end"
fi

# ─── SPEC-3: a configured work branch gets the run's commits ──────────────────
print_test_section "SPEC-3: the work branch is pushed at the stage end"
( cd "$REPO" && echo work > w.txt && git add w.txt && git commit -q -m "stage work" ) >/dev/null 2>&1
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'more\n' >> "$STATE/artifacts/test-author-result.json"
( cd "$REPO" && ZBUILD_WORKSPACE_BRANCH="zbuild/issue-$_ID-ci" \
    _runner_snapshot_artifacts "$STATE" "build" ) >/dev/null 2>&1
assert_eq "[SPEC-3] the work branch on origin is the run's HEAD" "$HEAD_SHA" \
    "$(_on_origin "zbuild/issue-$_ID-ci")"

# ─── SPEC-4: no work branch declared → nothing pushed at the stage end ───────
print_test_section "SPEC-4: a run with no declared work branch pushes nothing at a stage end"
_state_before="$(_on_origin "$STATE_BRANCH")"
_ci_before="$(git -C "$REPO" ls-remote --heads origin 2>/dev/null | /usr/bin/grep -c -- '-ci$')"
printf 'again\n' >> "$STATE/artifacts/test-author-result.json"
( cd "$REPO" && unset ZBUILD_WORKSPACE_BRANCH && _runner_snapshot_artifacts "$STATE" "test" ) >/dev/null 2>&1
assert_eq "[SPEC-4] no work branch is pushed" "$_ci_before" \
    "$(git -C "$REPO" ls-remote --heads origin 2>/dev/null | /usr/bin/grep -c -- '-ci$')"
assert_eq "[SPEC-4] the state branch on origin did not move" "$_state_before" "$(_on_origin "$STATE_BRANCH")"
assert_eq "[SPEC-4] …but the snapshot was still taken locally" "0" \
    "$(git -C "$REPO" diff --quiet "refs/heads/$STATE_BRANCH" "$_state_before" -- 2>/dev/null && echo 1 || echo 0)"

# ─── SPEC-5: a credential-looking artifact blocks the push ───────────────────
print_test_section "SPEC-5: a snapshot that looks like it carries a credential is not pushed"
_state_before="$(_on_origin "$STATE_BRANCH")"
printf 'token=ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$STATE/artifacts/leak.txt"
( cd "$REPO" && ZBUILD_WORKSPACE_BRANCH="zbuild/issue-$_ID-ci" _runner_snapshot_artifacts "$STATE" "build" ) >/dev/null 2>&1
assert_eq "[SPEC-5] the state branch on origin did not move" "$_state_before" "$(_on_origin "$STATE_BRANCH")"
rm -f "$STATE/artifacts/leak.txt"

# ─── control: the harness snapshots a PASSING member (so SPEC-1 tests rc, not setup)
( cd "$REPO" && _CYCLE_TRAP_CYCLE_ID=c _CYCLE_TRAP_ITER=1 \
    _cycle_emit_member_dispatch_complete 1 "impact" 0 "pass" "complete" ) >/dev/null 2>&1
assert_eq "[control] a passing member is snapshotted in this harness" "1" \
    "$(git -C "$REPO" rev-parse -q --verify "refs/heads/$STATE_BRANCH" >/dev/null 2>&1 && echo 1 || echo 0)"

print_test_results
exit $((FAIL > 0))
