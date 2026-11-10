#!/usr/bin/env bash
# tests/unit/judge-base-code-test.sh — the code from before the change, for a
# judge to read (#2464, ADR-072 §2, ADR-069 §2).
#
# Why: design's coverage check judged "the code already does this" on the
# branch's own version of the code (#1805 run 41679237388), and saw ten lines
# of it. The claim is about the code from before the change.
#
# B1 the copy holds the base commit's code, not the branch's
# B2 it is made once: a second ask reuses it
# B3 it cannot be written to
# B4 it sits outside the repository, on no branch, and leaves `git status` clean
# B5 a new base commit gets a new copy
# B6 teardown's release removes it, and git forgets it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the code from before the change, for a judge to read (#2464)"
setup_test_env "judge-base-code"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"

R="$TEST_TEMP_DIR/repo"
mkdir -p "$R/scripts"
(
    cd "$R" || exit 1
    git init -q -b main
    git config user.email t@t; git config user.name t
    printf 'old_code() { echo before; }\n' > scripts/a.sh
    git add -A; git commit -qm base
    git checkout -qb feature
    printf 'new_code() { echo after; }\n' > scripts/a.sh
    git commit -qam change
)
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state/runs/r1"
mkdir -p "$ZBUILD_STATE_DIR/artifacts"

print_test_section "B1-B4"
_b=""
judge_base_dir_v _b "$R"
assert_eq "[B1] a copy was made" "0" "$?"
assert_eq "[B1] it holds the base commit's code" "old_code() { echo before; }" "$(cat "$_b/scripts/a.sh" 2>/dev/null)"
_b2=""
judge_base_dir_v _b2 "$R"
assert_eq "[B2] a second ask gets the same copy" "${_b:-<none>}" "${_b2:-<none made>}"
assert_eq "[B2] ...and makes no second one" "2" "$(git -C "$R" worktree list | grep -c .)"
if [[ -n "$_b" && -e "$_b/scripts/a.sh" && ! -w "$_b/scripts/a.sh" ]]; then
    assert_pass "[B3] the copy cannot be written to"
else
    assert_fail "[B3] the copy cannot be written to" "writable: $_b/scripts/a.sh"
fi
case "${_b:-$R}/" in
    "$R"/*) assert_fail "[B4] the copy is outside the repository" "$_b" ;;
    *)      assert_pass "[B4] the copy is outside the repository" ;;
esac
assert_eq "[B4] ...and on no branch" "" "$(git -C "$_b" symbolic-ref -q HEAD 2>/dev/null)"
assert_eq "[B4] the repository's status stays clean" "" "$(git -C "$R" status --porcelain)"

print_test_section "B5: a new base commit"
( cd "$R" && git checkout -q main && printf 'old_code() { echo moved; }\n' > scripts/a.sh && git commit -qam moved \
    && git checkout -q feature && git merge -q --no-edit main -X ours >/dev/null 2>&1 )
_b3=""
judge_base_dir_v _b3 "$R"
assert_eq "[B5] a new base commit gets a new copy" "old_code() { echo moved; }" "$(cat "$_b3/scripts/a.sh" 2>/dev/null)"
assert_eq "[B5] ...and the old one is gone" "2" "$(git -C "$R" worktree list | grep -c .)"

print_test_section "B6: teardown's release removes it"
(
    export ZBUILD_REPO_ROOT="$R"
    cd "$R" || exit 1
    # shellcheck source=../../plugins/tool/teardown/plugin.sh
    source "$REPO_ROOT/plugins/tool/teardown/plugin.sh"
    printf '{"stage_statuses":{}}\n' > "$ZBUILD_STATE_DIR/pipeline-state.json"
    [[ -n "$_b3" && -d "$_b3" ]] || exit 3
    ZBUILD_TEARDOWN_SCOPE=release teardown_run teardown "$ZBUILD_STATE_DIR/pipeline-state.json" >/dev/null 2>&1
)
assert_eq "[B6] the copy was there for teardown to remove" "0" "$?"
assert_eq "[B6] the copy is removed" "absent" "$([[ -e "$_b3" ]] && printf present || printf absent)"
assert_eq "[B6] ...and git forgets it" "1" "$(git -C "$R" worktree list | grep -c .)"

cleanup_test_env
print_test_results
