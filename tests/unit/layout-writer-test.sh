#!/usr/bin/env bash
# Tests: the WRITER actually uses the layout resolver (#141, ADR-059 §1/§2).
#
# WHY THIS FILE EXISTS. tests/unit/layout-switch-test.sh asserts the RESOLVER —
# every one of its cases calls zbuild_layout_run_state_dir directly. It passed
# throughout while the switch was completely inert in production: runner.sh read
# $_runner_issue ~35 lines BEFORE that variable was assigned, so a fresh run
# always derived an EMPTY key, took the no-identity fallback, and kept the flat
# shape. `~/.zbuild/repos/` was never created by any real run, and nothing said
# so because "empty key" is also the legitimate answer for a run with no issue.
#
# A resolver test cannot catch that. This file drives `main` and asserts on
# WHERE THINGS LANDED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/layout.sh
source "$REPO_ROOT/core/state/layout.sh"
# shellcheck source=../../scripts/lib/worktree.sh
source "$REPO_ROOT/scripts/lib/worktree.sh"

print_test_header "layout WRITER — a real run lands under its issue (#141)"
setup_test_env "zb-layout-writer"

# #1921 follow-up: 1809 is a real issue. Every occurrence here is the SAME
# logical id — the identity, the run-id suffix and the expected paths — so it
# becomes one reserved id rather than N literals that could drift apart.
_ZB_ISSUE="$(zb_test_issue)"

# A repo with a known remote, so the repo segment is deterministic.
_repo="$TEST_TEMP_DIR/repo"; mkdir -p "$_repo"
(
  cd "$_repo" && git init -q -b main . \
    && git remote add origin 'git@github.com:ezigus/zBuild.git' \
    && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -qm seed
) >/dev/null 2>&1

# _drive <issue> — run the pipeline far enough to create its state dir, with
# every stage stubbed out. Deliberately does NOT set ZBUILD_STATE_DIR: pinning it
# sets _state_is_default=false and disables the very switch under test.
_drive() {
    local _issue="$1"
    (
        set +e
        cd "$_repo" || exit 1
        export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
        export ZBUILD_DATA_ROOT="$TEST_TEMP_DIR/data"
        export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"
        export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
        export ZBUILD_CONTRACT_VALIDATOR=warn
        export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
        export ZBUILD_NO_ISSUE_LOCK=1
        export ZBUILD_RUN_ID="r-${_issue}"
        unset ZBUILD_STATE_DIR ZBUILD_STATE_FILE
        # shellcheck disable=SC1091
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
        resolve_template_file() { echo "$REPO_ROOT/tests/fixtures/templates/route-back-cycles.yaml"; }
        cycle_orchestrator_run() { _CYCLE_LAST_TERMINATED_REASON="converged"; _CYCLE_LAST_ITERATIONS=1; return 0; }
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
        runner_read_stage_verdict() { echo "pass"; }
        plugin_hook_call() { return 0; }
        main --issue "$_issue" --template route-back-cycles >/dev/null 2>&1
    )
}

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
export ZBUILD_DATA_ROOT="$TEST_TEMP_DIR/data"
export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"

# ─── [SPEC-1][change] a real run's STATE lands under its issue ──────────────
print_test_section "[SPEC-1][change] the writer nests state under issues/<N>"

_drive "$_ZB_ISSUE"
_expect_state="$( cd "$_repo" && zbuild_layout_run_state_dir issue-$_ZB_ISSUE r-$_ZB_ISSUE )"
assert_file_exists "[SPEC-1] state written at the ISSUE-keyed path" \
    "$_expect_state/pipeline-state.json"
# And NOT at the flat one. Asserting only the positive would still pass if the
# writer wrote both, or if the expectation itself drifted.
if [[ -f "$ZBUILD_STATE_ROOT/runs/r-$_ZB_ISSUE/pipeline-state.json" ]]; then
    assert_fail "[SPEC-1] state ALSO landed in the pre-#141 flat path" \
        "the switch did not take effect: $ZBUILD_STATE_ROOT/runs/r-$_ZB_ISSUE"
else
    assert_pass "[SPEC-1] and NOT in the pre-#141 flat path"
fi

# ─── [SPEC-2][change] the WORKTREE is keyed by issue, not by run ────────────
# ADR-059 §2: a worktree holds a branch and the branch is named for the issue.
# One tree per issue is what removes the #1658/#1869 collision by construction.
print_test_section "[SPEC-2][change] one tree per ISSUE (ADR-059 §2)"

_wt_issue="$( cd "$_repo" && zbuild_worktree_path issue-$_ZB_ISSUE )"
assert_contains "[SPEC-2] the tree path is issue-keyed" "$_wt_issue" "/issues/$_ZB_ISSUE/worktree"
_rec="$_expect_state/run-worktree.txt"
if [[ -f "$_rec" ]]; then
    assert_eq "[SPEC-2] the run recorded the ISSUE-keyed tree" "$_wt_issue" "$(head -1 "$_rec")"
else
    skip_test "[SPEC-2] no worktree recorded (worktrees disabled in this env)"
fi

# ─── [SPEC-3][change] two runs of one issue share ONE tree ─────────────────
print_test_section "[SPEC-3][change] a second run of the same issue reuses the tree"

_a="$( cd "$_repo" && zbuild_worktree_path issue-$_ZB_ISSUE )"
_b="$( cd "$_repo" && zbuild_worktree_path issue-$_ZB_ISSUE )"
assert_eq "[SPEC-3] same issue, same tree" "$_a" "$_b"
_c="$( cd "$_repo" && zbuild_worktree_path issue-1810 )"
if [[ "$_a" == "$_c" ]]; then
    assert_fail "[SPEC-3] two different issues share one tree" "branch collision by construction"
else
    assert_pass "[SPEC-3] a different issue gets a different tree"
fi

# ─── [SPEC-4][guard] no identity ⇒ still per-run, not an invented bucket ────
print_test_section "[SPEC-4][guard] a run with no identity keeps the per-run tree"

_wt_run="$( cd "$_repo" && zbuild_worktree_path 20260825-1 )"
assert_contains "[SPEC-4] falls back to the per-run path" "$_wt_run" "/runs/20260825-1/worktree"

# ─── [SPEC-5][guard] run_id extraction REFUSES an issue-keyed tree ─────────
# The plan listed this among the six silent sites: the naive leaf walk returns
# the issue number typed as a run_id, rc=0.
print_test_section "[SPEC-5][guard] an issue tree is not mistaken for a run id"

_rc=0; zbuild_worktree_run_id "$_wt_issue" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-5] refuses to type an issue number as a run_id" "1" "$_rc"
assert_eq "[SPEC-5] but still labels the owner for diagnostics" \
    "issue $_ZB_ISSUE" "$(zbuild_worktree_owner "$_wt_issue")"
assert_eq "[SPEC-5] a per-run tree still yields its run id" \
    "20260825-1" "$(zbuild_worktree_run_id "$_wt_run")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
