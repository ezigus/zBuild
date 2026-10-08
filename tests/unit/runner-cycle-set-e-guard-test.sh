#!/usr/bin/env bash
# Unit (#766): the runner's cycle-dispatch call site must capture a non-zero
# rc WITHOUT tripping set -e even when the orchestrator (or its callees)
# re-enable set -e mid-stream. Since #1850 (ADR-054 §4) the loop returns only 0
# or 1 and names how it ended on _CYCLE_LAST_OUTCOME (it used to be rc 1/2/3). The legacy `set +e; orch_run; _rc=$?; set -e` pattern was
# fragile because callees could turn set -e back on, causing the rc=1 return
# to abort the runner shell before the rc-table branches at runner.sh:1281.
#
# Repro: simulate a callee that returns rc=1 AND has set -e enabled at return.
# The runner's call-site idiom MUST capture rc=1 cleanly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner cycle-dispatch set -e guard (#766)"
setup_test_env "runner-cycle-set-e-guard"

# A stand-in for cycle_orchestrator_run that returns rc=1 AND leaves set -e on
# (mimicking the observed mid-stream re-enable that caused #766).
_buggy_callee() {
    set -e
    return 1
}

# T1: legacy pattern (set +e ... set -e) trips when callee returns non-zero
# under set -e — script aborts before reaching the post-set -e command.
# We verify this by running it in a subshell and observing the subshell's rc.
t1_check() (
    set -e
    set +e
    _buggy_callee
    _rc=$?
    set -e
    # If we reach here, set -e didn't trip; legacy pattern works in THIS shell.
    # But the actual bug only manifests when the function call is INSIDE a
    # larger script under set -e — the rc=1 propagates to the calling for-loop.
    echo "$_rc"
    return 0
)
t1_rc=$(t1_check 2>&1 || true)
# Document current behavior: the inline pattern returns "1" cleanly in this
# isolated context. The bug arose in the runner's specific calling context.
[[ "$t1_rc" == "1" ]] \
    && assert_pass "T1: legacy pattern returns rc=1 in isolated subshell (bug only manifests in runner's caller context)" \
    || assert_fail "T1: legacy pattern unexpectedly aborted" "got: '$t1_rc'"

# T2: NEW pattern (`... && _rc=0 || _rc=$?`) MUST capture rc=1 without trip
# regardless of set -e state inside the callee.
t2_check() (
    set -e
    _rc=99
    _buggy_callee && _rc=0 || _rc=$?
    echo "$_rc"
)
t2_rc=$(t2_check 2>&1 || true)
assert_eq "T2: new pattern captures rc=1 cleanly under set -e" "1" "$t2_rc"

# T3: NEW pattern also handles rc=0 correctly (happy path).
_zero_callee() { set -e; return 0; }
t3_check() (
    set -e
    _rc=99
    _zero_callee && _rc=0 || _rc=$?
    echo "$_rc"
)
t3_rc=$(t3_check 2>&1 || true)
assert_eq "T3: new pattern captures rc=0 cleanly" "0" "$t3_rc"

# T4: NEW pattern keeps the outcome word a loop sets before returning 1 — a
# plateau and an interrupted end both return 1 (#1850; they were rc=2 / rc=4),
# so the word is the only thing the runner can branch on, and the idiom must
# not lose it.
_unconverged_callee() { set -e; _CYCLE_LAST_OUTCOME="unconverged"; return 1; }
_interrupted_callee() { set -e; _CYCLE_LAST_OUTCOME="interrupted"; return 1; }
t4_check() (
    set -e
    _rc=99
    _unconverged_callee && _rc=0 || _rc=$?
    echo -n "${_rc} ${_CYCLE_LAST_OUTCOME:-unset}|"
    _interrupted_callee && _rc=0 || _rc=$?
    echo "${_rc} ${_CYCLE_LAST_OUTCOME:-unset}"
)
t4_rc=$(t4_check 2>&1 || true)
assert_eq "T4: new pattern captures rc=1 and keeps the outcome word under set -e" \
    "1 unconverged|1 interrupted" "$t4_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
