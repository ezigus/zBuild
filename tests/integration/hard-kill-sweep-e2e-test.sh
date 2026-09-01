#!/usr/bin/env bash
# Tests: a SIGKILLed runner's children are freed by the next sweep (#2024/#2018).
#
# This is the case every other test in this area approximates. #2018's tests
# drive the scanner and the applier with records a FIXTURE wrote; the teardown
# test drives the normal-exit path. Neither one kills the runner, and killing
# the runner is the entire point — an EXIT trap cannot run, so the only thing
# left is what is on disk.
#
# It is also the test that would have caught #2024 immediately. Until now the
# engine recorded its OWN process group at dispatch, so a real hard kill left a
# record naming a group nothing could signal. Every unit test passed, because
# every unit test wrote the record itself.
#
# Shape: spawn a suite in its own group, register it the way tool/test does,
# SIGKILL the owning shell, then run the sweep and assert the suite is gone.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a hard-killed runner's children are freed by the next sweep (#2024)"
setup_test_env "hard-kill-sweep"

DR="$TEST_TEMP_DIR/data"
SD="$DR/repos/zbuild/issues/4242/runs/20260901140000-9999"
mkdir -p "$SD/runtime"

# ── A stand-in runner: registers a real group, then is SIGKILLed ────────────
# `set -m` is what tool/test does, and it is what makes the child a group leader
# distinct from this shell — the property the old dispatch record never had.
cat > "$TEST_TEMP_DIR/runner.sh" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/scripts/lib/proc-group.sh"
export ZBUILD_STATE_DIR="$SD"
export ZBUILD_CURRENT_STAGE="test"
set -m
sleep 600 &
_child=\$!
echo "\$_child" > "$TEST_TEMP_DIR/suite.pid"
_pg="\$(zbuild_pg_resolve "\$_child")"
zbuild_pg_register "\$_pg"
echo ready > "$TEST_TEMP_DIR/ready"
wait "\$_child"
RUNNER
chmod +x "$TEST_TEMP_DIR/runner.sh"

# No setsid: it is absent on a stock macOS, and it is not needed. What this test
# requires is that the SUITE sit in a group distinct from the runner's, and the
# runner's own `set -m` is what provides that — exactly as tool/test does it.
"$TEST_TEMP_DIR/runner.sh" >/dev/null 2>&1 &
RUNNER_PID=$!
# Silence the shell's "Killed: 9" job-control notice on the SIGKILL below;
# it is expected here and reads as a suite error in CI output.
disown "$RUNNER_PID" 2>/dev/null || true
_i=0; while [[ ! -f "$TEST_TEMP_DIR/ready" && $_i -lt 100 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
SUITE_PID="$(cat "$TEST_TEMP_DIR/suite.pid" 2>/dev/null || true)"

# NOT a skip. A skip here is indistinguishable from the mechanism being broken,
# and "All 0 tests passed" is the same green-but-proving-nothing shape this file
# exists to close. If the harness cannot stage the scenario, that is a failure.
if [[ -z "$SUITE_PID" ]] || ! kill -0 "$SUITE_PID" 2>/dev/null; then
    assert_fail "harness: a suite starts in its own process group" \
        "no suite pid — nothing below this line would have proven anything"
    print_test_results
    exit 1
fi

# ── SPEC-1: the runner recorded a group that is NOT its own ────────────────
# The #2024 defect in one assertion. A record equal to the recorder's own group
# is unkillable, and that is what was on disk for every stage until now.
REC="$SD/runtime/stages/test.pgid"
if [[ -f "$REC" ]]; then
    IFS=$'\t' read -r RECPG RECSTART < "$REC"
    RUNNER_PG="$(ps -o pgid= -p "$RUNNER_PID" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "$RECPG" && "$RECPG" != "$RUNNER_PG" ]]; then
        assert_pass "SPEC-1: the record names the suite's group, not the runner's"
    else
        assert_fail "SPEC-1: the record names the suite's group, not the runner's" \
            "recorded=$RECPG runner=$RUNNER_PG — an unkillable record (#2024)"
    fi
else
    assert_fail "SPEC-1: the record names the suite's group, not the runner's" "no record written"
fi

# ── SPEC-2: SIGKILL the runner — no trap runs, the suite survives ──────────
# Establishing the precondition. If the suite died with its parent there would
# be nothing for the sweep to prove.
kill -KILL "$RUNNER_PID" 2>/dev/null || true
_i=0; while kill -0 "$RUNNER_PID" 2>/dev/null && [[ $_i -lt 40 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
if kill -0 "$SUITE_PID" 2>/dev/null; then
    assert_pass "SPEC-2: the suite outlives a SIGKILLed runner (the leak #1748 is about)"
else
    assert_fail "SPEC-2: the suite outlives a SIGKILLed runner" \
        "it died with its parent — this run proves nothing about the sweep"
fi

# ── SPEC-3: the sweep finds it, and says it is ours ────────────────────────
source "$REPO_ROOT/scripts/lib/proc-group.sh"
source "$REPO_ROOT/scripts/lib/cleanup.sh"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"test.pgid"*$'\t'kill$'\t'* ]]; then
    assert_pass "SPEC-3: the sweep proves the orphaned group is ours"
else
    assert_fail "SPEC-3: the sweep proves the orphaned group is ours" "got: $plan"
fi

# ── SPEC-4: dry-run does not touch it ──────────────────────────────────────
_cleanup_apply_pgid_plan "$plan" "true" "$DR" >/dev/null 2>&1 || true
if kill -0 "$SUITE_PID" 2>/dev/null; then
    assert_pass "SPEC-4: a dry-run sweep leaves the orphan alone"
else
    assert_fail "SPEC-4: a dry-run sweep leaves the orphan alone" "killed on a dry run"
fi

# ── SPEC-5: --apply frees it. The whole point. ─────────────────────────────
_cleanup_apply_pgid_plan "$plan" "false" "$DR" >/dev/null 2>&1 || true
_i=0; while kill -0 "$SUITE_PID" 2>/dev/null && [[ $_i -lt 60 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
if ! kill -0 "$SUITE_PID" 2>/dev/null; then
    assert_pass "SPEC-5: the sweep frees a suite orphaned by a hard kill"
else
    assert_fail "SPEC-5: the sweep frees a suite orphaned by a hard kill" \
        "pid $SUITE_PID still running — the leak survives the mechanism built to stop it"
    kill -9 "$SUITE_PID" 2>/dev/null || true
fi

# ── SPEC-6: the record is reaped, so runtime/ is not a graveyard ───────────
if [[ ! -f "$REC" ]]; then
    assert_pass "SPEC-6: the spent record is removed"
else
    assert_fail "SPEC-6: the spent record is removed" "$REC survived"
fi

print_test_results
