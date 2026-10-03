#!/usr/bin/env bash
# tests/e2e/failed-run-says-so-test.sh — a run whose last stage fails records
# that it failed (#2265).
#
# Why: #1844 run 37066147994's `pr` stage failed (gh pr create refused). The
# engine announced the halt, and then the runner process ended with nothing
# logged: no stage.fail, no pipeline.end, no status for `pr` in the state file.
# Only the exit trap ran, so the run read "aborted" in the log and "interrupted"
# in the state file and the run-status comment. Nothing interrupted it.
#
# The cause: cycle_dispatch_stage turned errexit back ON after running the
# plugin (`set +e; plugin_hook_call …; _cd_rc=$?; set -e`), undoing its
# caller's `set +e`. Its `return 1` then ended the runner on the spot — for any
# top-level stage that fails.
#
# This replays that ending on the mocked full run (the parity fixture) with
# `gh pr create` refusing.
#
# E1 [change] the failing stage is recorded as failed
# E2 [change] the run records how it ended: pipeline.end status=failed
# E3 [change] the run-status comment says failed, not interrupted
# E4 [guard]  the run exits non-zero
# E5 [guard]  the state file keeps ADR-006's resumable word for a mid-stage
#             failure ("interrupted": aborted mid-flight, resumable) — the
#             comment, not the state file, is what tells a person it failed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a run whose last stage fails says so (#2265)"
setup_test_env "failed-run-says-so"

FIXTURE="$REPO_ROOT/tests/golden/parity/run-fixture.sh"
RUN_DIR="$TEST_TEMP_DIR/run"; BIN_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$RUN_DIR/events" "$BIN_DIR"

_run_rc=0
(
    unset GITHUB_ACTIONS CI GITHUB_STEP_SUMMARY RUNNER_OS 2>/dev/null || true
    FIXTURE_GH_PR_CREATE_FAIL=1 FIXTURE_STATE_DIR="$RUN_DIR" FIXTURE_BIN_DIR="$BIN_DIR" \
        ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/pc" \
        bash "$FIXTURE" > "$TEST_TEMP_DIR/run.log" 2>&1
) || _run_rc=$?

EVENTS="$RUN_DIR/events/events.jsonl"
STATE="$(find "$RUN_DIR" -name pipeline-state.json -not -path '*/restored-artifacts/*' 2>/dev/null | head -n1)"   # sigpipe-ok: find output is small and fully read

# The replay must actually reach the pr stage, or every assertion below is vacuous.
if jq -e 'select(.type=="stage.start" and .data.stage=="pr")' "$EVENTS" >/dev/null 2>&1; then
    assert_pass "[setup] the run reached the pr stage"
else
    assert_fail "[setup] the run reached the pr stage" "$(tail -5 "$TEST_TEMP_DIR/run.log" 2>/dev/null)"
fi

assert_eq "[E1] the pr stage is recorded as failed" "failed" \
    "$(jq -r '.stage_statuses.pr // "none"' "$STATE" 2>/dev/null)"
assert_eq "[E2] pipeline.end records status=failed" "failed" \
    "$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS" 2>/dev/null | tail -n1)"
# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"
_body="$(rsc_render_body "$EVENTS" "$TEST_TEMP_DIR" 2>/dev/null | head -n3)"   # sigpipe-ok: rendered body is captured in full by $( ) before head reads it
assert_contains "[E3] the run-status comment says failed" "$_body" "**failed**"
assert_eq "[E4] the run exits non-zero" "1" "$([[ $_run_rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "[E5] the state file keeps ADR-006's resumable status" "interrupted" "$(jq -r '.status // "none"' "$STATE" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
