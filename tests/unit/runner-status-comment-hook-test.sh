#!/usr/bin/env bash
# Tests: the runner spawns and reaps the run-status comment sidecar (#2131,
# ADR-064). Spec pins on the trap placement (the trap is defined inside the
# runner's main function, so it is read as text), behaviour on the two
# top-level functions, and the harness kill switch that keeps every test —
# including the dogfood's nested suite — off GitHub.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner — status-comment sidecar spawn/reap (#2131)"
setup_test_env "runner-status-comment-hook"

RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../core/pipeline/runner.sh
source "$RUNNER"

# ─── SPEC-1: the two functions exist at top level ───────────────────────────
assert_eq "[SPEC-1] _runner_status_comment_spawn is defined" "ok" \
    "$(declare -F _runner_status_comment_spawn >/dev/null 2>&1 && echo ok || echo missing)"
assert_eq "[SPEC-1] _runner_status_comment_reap is defined" "ok" \
    "$(declare -F _runner_status_comment_reap >/dev/null 2>&1 && echo ok || echo missing)"

# ─── SPEC-2: trap placement (text pins) ─────────────────────────────────────
# Normal path: the reap sits on the `_runner_ended` early return, AFTER
# pipeline.end and the always-run stages are on disk. Abnormal path: the reap
# is the LAST statement of the trap, after pipeline.aborted/pipeline.abort.
trap_body="$(awk '/^    _runner_abort_trap\(\) \{/{f=1} f{print} f && /^    \}$/{exit}' "$RUNNER")"
assert_contains "[SPEC-2] reap on the _runner_ended early return" \
    "$trap_body" 'if [[ "$_runner_ended" == "true" ]]; then _runner_status_comment_reap; return 0; fi'
last_stmt="$(printf '%s\n' "$trap_body" | grep -vE '^\s*(#|$)' | tail -2 | sed -n 1p | sed 's/^ *//')"
assert_eq "[SPEC-2] reap is the last statement of the abort trap" "_runner_status_comment_reap" "$last_stmt"
assert_contains "[SPEC-2] the signal walk exempts the sidecar pid" \
    "$(awk '/_w15h_collect_pgid\(\) \{/{f=1} f{print} f && /^            \}$/{exit}' "$RUNNER")" \
    '_RUNNER_STATUS_COMMENT_PID'
assert_contains "[SPEC-2] spawn is called after the events path is exported" \
    "$(awk '/_ZBUILD_EVENTS_PINNED" \]\]; then/{f=1} f{print} f && /_runner_status_comment_spawn/{exit}' "$RUNNER" | tail -1)" \
    '_runner_status_comment_spawn'

# ─── SPEC-3: the harness kill switch ────────────────────────────────────────
assert_contains "[SPEC-3] scripts/run-tests.sh pins ZBUILD_STATUS_COMMENT=0" \
    "$(grep -E '^export ZBUILD_STATUS_COMMENT=0' "$REPO_ROOT/scripts/run-tests.sh")" 'ZBUILD_STATUS_COMMENT=0'
assert_contains "[SPEC-3] the parity fixture pins ZBUILD_STATUS_COMMENT=0" \
    "$(grep -E '^export ZBUILD_STATUS_COMMENT=0' "$REPO_ROOT/tests/golden/parity/run-fixture.sh")" 'ZBUILD_STATUS_COMMENT=0'

# ─── SPEC-4: spawn gates ────────────────────────────────────────────────────
STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE"
cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$1 $2" == "auth status" ]] && exit "${GH_AUTH_RC:-0}"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" remote add origin https://github.com/testuser/testrepo.git
export ZBUILD_ISSUE=90000042 ZBUILD_RUN_ID=r-hook
unset NO_GITHUB
export ZBUILD_STATUS_COMMENT=1     # the harness pins 0 (SPEC-3); this section wants the gates themselves

_RUNNER_STATUS_COMMENT_PID=""
ZBUILD_STATUS_COMMENT=0 _runner_status_comment_spawn "$STATE" "$STATE/events.jsonl" "$REPO"
assert_eq "[SPEC-4] ZBUILD_STATUS_COMMENT=0 → nothing spawned" "" "$_RUNNER_STATUS_COMMENT_PID"
assert_file_not_exists "[SPEC-4] …and no trace on disk (the parity golden lists every state-dir file)" "$STATE/status-comment.log"

_RUNNER_STATUS_COMMENT_PID=""
GH_AUTH_RC=1 _runner_status_comment_spawn "$STATE" "$STATE/events.jsonl" "$REPO"
assert_eq "[SPEC-4] gh auth failure → nothing spawned" "" "$_RUNNER_STATUS_COMMENT_PID"

_RUNNER_STATUS_COMMENT_PID=""
ZBUILD_ISSUE=0 _runner_status_comment_spawn "$STATE" "$STATE/events.jsonl" "$REPO"
assert_eq "[SPEC-4] goal run (issue 0) → nothing spawned" "" "$_RUNNER_STATUS_COMMENT_PID"

NOGH="$TEST_TEMP_DIR/nogh"; mkdir -p "$NOGH"; git -C "$NOGH" init -q; git -C "$NOGH" remote add origin git@gitlab.com:x/y.git
_RUNNER_STATUS_COMMENT_PID=""
_runner_status_comment_spawn "$STATE" "$STATE/events.jsonl" "$NOGH"
assert_eq "[SPEC-4] non-github origin → nothing spawned" "" "$_RUNNER_STATUS_COMMENT_PID"

# All gates open → a sidecar process exists and is reaped cleanly.
_RUNNER_STATUS_COMMENT_PID=""
_runner_status_comment_spawn "$STATE" "$STATE/events.jsonl" "$REPO"
if [[ -n "$_RUNNER_STATUS_COMMENT_PID" ]] && kill -0 "$_RUNNER_STATUS_COMMENT_PID" 2>/dev/null; then
    assert_pass "[SPEC-4] all gates open → sidecar spawned (pid $_RUNNER_STATUS_COMMENT_PID)"
else
    assert_fail "[SPEC-4] all gates open → sidecar spawned" "pid='$_RUNNER_STATUS_COMMENT_PID' log: $(cat "$STATE/status-comment.log" 2>/dev/null)"
fi
spawned="$_RUNNER_STATUS_COMMENT_PID"
export ZBUILD_STATUS_COMMENT_REAP_TIMEOUT=5
_runner_status_comment_reap; rc=$?
assert_eq "[SPEC-4] reap returns 0" "0" "$rc"
assert_eq "[SPEC-4] reap clears the pid" "" "$_RUNNER_STATUS_COMMENT_PID"
if kill -0 "$spawned" 2>/dev/null; then
    assert_fail "[SPEC-4] the sidecar is gone after the reap" "pid $spawned alive"; kill -KILL "$spawned" 2>/dev/null
else
    assert_pass "[SPEC-4] the sidecar is gone after the reap"
fi
_runner_status_comment_reap; rc=$?
assert_eq "[SPEC-4] a second reap is a no-op returning 0" "0" "$rc"

# ─── SPEC-5: reap is bounded — a child that ignores TERM is KILLed ─────────
bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
_RUNNER_STATUS_COMMENT_PID=$!
stubborn=$_RUNNER_STATUS_COMMENT_PID
export ZBUILD_STATUS_COMMENT_REAP_TIMEOUT=1
t0=$(date +%s)
_runner_status_comment_reap; rc=$?
t1=$(date +%s)
assert_eq "[SPEC-5] reap of a TERM-ignoring child returns 0" "0" "$rc"
if [[ $(( t1 - t0 )) -le 4 ]]; then
    assert_pass "[SPEC-5] reap returned within the bound ($(( t1 - t0 ))s)"
else
    assert_fail "[SPEC-5] reap returned within the bound" "took $(( t1 - t0 ))s"
fi
if kill -0 "$stubborn" 2>/dev/null; then
    assert_fail "[SPEC-5] the stubborn child was KILLed" "alive"; kill -KILL "$stubborn" 2>/dev/null
else
    assert_pass "[SPEC-5] the stubborn child was KILLed"
fi

# ─── SPEC-6: the trap's rc is never the reap's ─────────────────────────────
# `set -e` is on inside the trap; every reap line must be `|| true`-safe.
reap_src="$(declare -f _runner_status_comment_reap)"
assert_eq "[SPEC-6] reap's last statement is return 0" "return 0" \
    "$(grep -vE '^\s*(#|\}|$)' <<< "$reap_src" | tail -1 | sed 's/^ *//;s/;$//')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
