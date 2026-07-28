#!/usr/bin/env bash
# Tests (#1265, SPEC-2): intake snapshots the PRE-EXISTING untracked set at
# run-start to ${state_dir}/intake-untracked-baseline.txt (NUL-delimited) and
# emits intake.untracked_baseline.captured count=N. The build scope-census
# baselines against this so a stray left by a prior run is never false-flagged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# #888: this file asserts IN-PLACE branch semantics (the main tree's HEAD moves,
# main-tree strays are visible). Worktree isolation is default-on and changes both
# — correctly: the branch lands in the per-run worktree and the developer's tree is
# left untouched. Pin this file to in-place mode so it keeps testing what it was
# written to test; worktree-mode behaviour is covered by
# tests/integration/intake-worktree-isolation-test.sh.
export ZBUILD_NO_WORKTREE=1


print_test_header "intake: writes intake-untracked-baseline.txt (#1265)"
setup_test_env "intake-1265-untracked-baseline"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"

REPO="$(setup_git_temp_repo zbuild-1265-repo)"
if [[ -z "$REPO" || ! -d "$REPO/.git" ]]; then
    assert_fail "setup_git_temp_repo created a usable repo" "no .git at $REPO"
    cleanup_test_env; print_test_results; exit 1
fi

STATE_DIR="$TEST_TEMP_DIR/state-1265"
mkdir -p "$STATE_DIR"

cd "$REPO" || exit 1

# Leave a PRE-EXISTING untracked stray in the tree (the #1214/#945 scenario).
mkdir -p "$REPO/config/templates"
printf 'stray perf fixture\n' > "$REPO/config/templates/runner-state-dir-minimal.yaml"

: > "$ZBUILD_EVENTS_JSONL"
(
    unset CI GITHUB_ACTIONS
    export ZBUILD_INTAKE_ALLOW_DIRTY=1
    _intake_create_workspace_branch "$STATE_DIR" 1265 "scope census baseline"
) > /tmp/intake-1265-out.$$ 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
    cat /tmp/intake-1265-out.$$ >&2
fi
assert_eq "branch creation rc=0" "0" "$rc"

# The baseline file must exist and contain the stray path.
assert_file_exists "intake-untracked-baseline.txt exists" \
    "$STATE_DIR/intake-untracked-baseline.txt"

# NUL-delimited → translate to newlines for the membership assertion.
got_paths="$(tr '\0' '\n' < "$STATE_DIR/intake-untracked-baseline.txt" 2>/dev/null || echo)"
if grep -Fxq 'config/templates/runner-state-dir-minimal.yaml' <<< "$got_paths"; then
    assert_pass "pre-existing stray captured in the untracked baseline"
else
    assert_fail "pre-existing stray captured in the untracked baseline" "not found in: $got_paths"
fi

# Event emitted with a count >= 1.
cap_count=$(grep -c '"intake.untracked_baseline.captured"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)
cap_count="${cap_count:-0}"
assert_gt "intake.untracked_baseline.captured emitted" "$cap_count" "0"
evt_n="$(jq -r 'select(.type=="intake.untracked_baseline.captured") | .data.count' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
assert_gt "captured count >= 1 (the stray)" "${evt_n:-0}" "0"

cd "$REPO_ROOT" || true
rm -f /tmp/intake-1265-out.$$
cleanup_test_env
print_test_results
exit $((FAIL > 0))
