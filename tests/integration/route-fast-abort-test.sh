#!/usr/bin/env bash
# Integration: route_to_model_loop fast pre-abort via process-group kill (Wave 15-G, #687).
#
# Background: Wave 8 (#612) added a per-PID kill in _route_loop_on_signal:
#   kill "$_ROUTE_LOOP_CHILD_PID"
# That only signals the top-level claude process. If claude (or any child
# it spawned) ignores or delays SIGTERM, the loop hangs until the child
# eventually exits — which can be many seconds. Wave 15-G narrows that
# window by spawning claude in its own process group and TERM-ing the
# entire group, then KILL-ing 1s later as a fallback.
#
# Strategy: stub `claude` traps and IGNORES SIGTERM, then sleeps for a
# long time. Drive route_to_model_loop in a subshell, send SIGTERM to the
# driver after ~500ms (TERM not INT; non-interactive backgrounded bash
# inherits SIG_IGN for SIGINT — see the longer note above the driver
# spawn below), and assert:
#   - the loop returns 130 within ~2.5s wall-clock
#   - no stub-claude processes are left running
#
# Before Wave 15-G: the per-PID TERM bounces off the trap and the test
# hangs for the full claude sleep (60s) — i.e. fails the time budget.
# After Wave 15-G: TERM goes to the whole process group, and the 1s
# delayed SIGKILL closes the window even if the entire group ignored
# TERM. Either way the loop exits within budget.
#
# #905: the SIGKILL escalation is now SYNCHRONOUS — _route_loop_on_signal
# blocks (via a local, reaped watchdog) until the child tree is actually
# reaped before returning, instead of detaching `{ sleep 1 && kill; } &`
# and returning immediately. The old detached backstop raced the caller's
# exit, intermittently leaving the stub alive past the assertion window
# (the route-fast-abort CI flake). Assertion (2) below now requires the
# stub dead shortly after loop-return, plus an elapsed_ms floor (1b) proving
# the handler waited rather than arming a detached backstop (#1975).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: route_to_model_loop fast pre-abort via PG kill (#687)"
setup_test_env "route-fast-abort"
# Wave 15-G's fast-abort guarantee relies on `setsid -w` to isolate the
# claude process group so the loop signal handler can TERM/KILL the whole
# tree safely. The contract is Linux-specific AND needs a working `setsid -w`:
# on a Linux host without util-linux (or without -w support) route.sh falls back
# to per-PID kill, which can't satisfy the 2.5s budget — so SKIP rather than fail
# a contract that isn't exercisable. CI (ubuntu-latest) ships setsid and runs it.
skip_unless_platform linux
skip_unless_capable "setsid -w unavailable — Wave 15-G PG-kill not exercisable" setsid -w true

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Unique marker so we can pgrep for OUR stub-claude processes only —
# even if some other stub `claude` is around in the test env.

# Stub claude: trap-and-ignore SIGTERM/INT, sleep long. Records its PID
# into a file so we can verify it was actually reaped.
mkdir -p "$TEST_TEMP_DIR/bin"
PID_FILE="$TEST_TEMP_DIR/stub-claude.pid"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
echo \$\$ >> "$PID_FILE"
trap '' TERM INT
# Burn 60s in 1s slices so the trap-ignore is observable AND so a kernel
# SIGKILL still finds us in the sleep, not in the bash dispatch loop.
i=0
while [[ \$i -lt 60 ]]; do
    sleep 1
    i=\$((i + 1))
done
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
# The identity the leftover check matches on (#1949). Unique per run.
_RFA_STUB_PATH="$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# Throwaway repo for route_to_model_loop's git diff capture.
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git commit -q -m seed
) >/dev/null

# Prompt file.
PF="$TEST_TEMP_DIR/prompt.txt"
echo "fast-abort test prompt" > "$PF"

# Driver: run route_to_model_loop in a child bash, send a signal to it
# after ~500ms, then time the full unwind. We use a real signal (not a
# function call) so we exercise the trap path end-to-end, including the
# negative-PGID kill syntax.
#
# We send SIGTERM (not SIGINT) because non-interactive bash backgrounded
# with `&` from a script-mode parent inherits SIG_IGN for SIGINT and
# cannot un-ignore it (POSIX). The router installs identical traps for
# both INT and TERM (see `_route_loop_install_traps` in route.sh), so
# TERM exercises the same code path the operator's Ctrl-C would. The
# existing sigint-aborts-pipeline-test (#612) covers the INT-via-mock-rc
# route — this test covers the explicit signal-delivery + PG-kill route.
DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<DRV
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/core/router/route.sh"
# Skip C6 precondition for this test (bootstrap-token-backed override
# already exported from the parent).
_route_lookup_model() { _ROUTE_MODEL_ID="stub-model"; return 0; }
# Resolve a short per-call timeout so this test never blocks the suite if
# the abort path itself regresses — the outer 5s ceiling below is the
# real assertion; this is belt-and-suspenders.
_route_resolve_timeout() { echo 30; }
_route_resolve_max_turns() { echo 5; }
# Drive the loop.
route_to_model_loop T2 "$PF" "$REPO" 5
echo "rc=\$?" > "$TEST_TEMP_DIR/loop.rc"
DRV
chmod +x "$DRIVER"

# Hard ceiling: if the abort regressed, kill the driver at 8s so the
# test suite doesn't hang. The assertion below treats anything >2.5s
# as a failure.
(
    sleep 8
    pkill -KILL -f "bash $DRIVER" 2>/dev/null || true
) &
WATCHDOG_PID=$!
disown $WATCHDOG_PID 2>/dev/null || true

DRV_LOG="$TEST_TEMP_DIR/driver.log"
bash "$DRIVER" >"$DRV_LOG" 2>&1 &
DRV_PID=$!

# Poll until stub-claude records its PID (readiness signal) before sending TERM,
# instead of a fixed `sleep 0.6` that raced claude-spawn under CI load (#947).
# 50ms steps up to a 5s ceiling; the 8s watchdog above is the hard backstop.
spawn_ceiling_ms=5000
spawn_deadline_ns=$(( $(date +%s%N) + spawn_ceiling_ms * 1000000 ))
pid_ready=0
while [[ $(date +%s%N) -lt $spawn_deadline_ns ]]; do
    if [[ -s "$PID_FILE" ]]; then
        pid_ready=1
        break
    fi
    sleep 0.05
done

start_ts=$(date +%s%N)
kill -TERM "$DRV_PID" 2>/dev/null || true

# Wait for driver to exit (or watchdog to kill it).
wait "$DRV_PID" 2>/dev/null || true
end_ts=$(date +%s%N)

# Kill watchdog if still around.
kill -KILL "$WATCHDOG_PID" 2>/dev/null || true

elapsed_ms=$(( (end_ts - start_ts) / 1000000 ))

# ─── Assertions ──────────────────────────────────────────────────────────────

# (0) Spawn readiness (#947): the poll above observed stub-claude record its PID
#     *before* we sent TERM. A premature signal (the old fixed `sleep 0.6` racing
#     spawn under load) would make the abort-timing assertion below measure a
#     no-op, so fail loudly here instead of silently passing.
if [[ "$pid_ready" == "1" ]]; then
    assert_pass "stub-claude PID recorded before signal (readiness poll, not fixed sleep)"
else
    assert_fail "stub-claude PID recorded before signal" \
        "poll hit ${spawn_ceiling_ms}ms ceiling with empty PID_FILE — spawn raced or failed"
fi

# (1) Abort within 2500ms wall-clock from signal delivery to driver exit.
#     TERM grace = 1s, KILL backstop = 1s, plus some unwind slack = 2.5s.
#     (We send SIGTERM to the driver — see header note about SIGINT
#     SIG_IGN inheritance in non-interactive backgrounded bash.)
if [[ $elapsed_ms -le 2500 ]]; then
    assert_pass "loop aborted within 2500ms of signal (actual=${elapsed_ms}ms)"
else
    assert_fail "loop aborted within 2500ms of signal" \
        "actual=${elapsed_ms}ms — per-PID kill bounced off claude's TERM trap (Wave 15-G regression)"
fi

# (1b) #1975: the SYNCHRONOUS-abort discriminator, moved here from the reap
#      window below.
#
#      _route_loop_on_signal must not return until the child tree it signalled
#      has actually been reaped (ADR-025). The stub ignores TERM, so `wait`
#      cannot return until the handler's own `{ sleep 1 && kill -KILL; }`
#      watchdog fires — a floor of ~1000ms. The pre-#905 backstop was a
#      DISOWNED subshell: the handler armed it and returned immediately, ~0ms.
#
#      That gap is the regression signal, and unlike the reap window it is
#      LOAD-MONOTONE: load can only make wall-clock larger, never smaller, so a
#      loaded runner cannot fake a synchronous abort. The reap window could only
#      ever be made unreliable by load, which is why #1975 kept failing on CI
#      while finding nothing wrong.
#
#      800ms floor: post-#905 measures ~1000ms, pre-#905 ~0-100ms. Wide margin
#      on both sides of a 10x separation.
if [[ $elapsed_ms -ge 800 ]]; then
    assert_pass "abort was SYNCHRONOUS, not a disowned backstop (actual=${elapsed_ms}ms >= 800ms)"
else
    assert_fail "abort was SYNCHRONOUS, not a disowned backstop" \
        "actual=${elapsed_ms}ms — handler returned before the child was reaped; the pre-#905 disowned-backstop shape is back (#905, ADR-025)"
fi

# (2) No stub-claude process from this driver is still running. #905 made the
#     abort SYNCHRONOUS — _route_loop_on_signal does not return until the child
#     tree has been SIGKILLed and reaped, so by the time the driver exited (the
#     `wait "$DRV_PID"` above returned) the stub is already dead. We allow only
#     a 2s reap window for the kernel to clear the reparented zombie's PID slot.
#     #1975: this window used to be 500ms because it was ALSO the check that a
#     detached backstop had not fired. It no longer carries that job — assertion
#     (1b) does, via a load-monotone elapsed_ms floor — so it can be generous
#     enough to survive a loaded runner. A genuine leak is a live 60s stub and
#     outlives any window; a slow reap is not a leak.
#     Millisecond-precise deadline (not integer `date +%s`, whose second-
#     granularity made the old window race between ~1s and ~2s under load).
# _rfa_is_my_stub <pid> — true only when <pid> is a stub-claude THIS test spawned.
# Reads /proc/<pid>/cmdline and matches the stub path, which is unique per run
# because TEST_TEMP_DIR is. A zombie's cmdline is EMPTY, so this also subsumes
# the #1942 zombie exclusion rather than duplicating it; the `ps` check below is
# kept as a second, independent signal so a future regression in either one is
# still caught by the other.
# Returns 0 = count it, 1 = do not. Deliberately TRI-state internally, because
# the two "cannot read it" cases mean opposite things and collapsing them makes
# a leak detector fail OPEN — the permissive-direction failure this whole
# initiative exists to remove:
#
#   /proc/<pid> absent          -> process is gone            -> skip
#   cmdline present but EMPTY   -> zombie (#1942)             -> skip
#   cmdline non-empty, no match -> PID reuse, a stranger      -> skip
#   cmdline non-empty, matches  -> our stub is alive          -> COUNT
#   /proc/<pid> exists, cmdline unreadable -> AMBIGUOUS       -> COUNT (fail closed)
#
# The last row is the one worth stating: an unreadable cmdline on a directory
# that still exists is not evidence of absence, so it is counted and the
# diagnostic below says why. Better a rare explained failure than a detector
# that quietly stops detecting.
# Identity check lives in tests/lib/proc-identity.sh so it can be driven on a
# platform that never runs this file (#1949). See that file for the five cases.
# shellcheck source=../lib/proc-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/proc-identity.sh"
_rfa_is_my_stub() { proc_is_my_process "$1" "$_RFA_STUB_PATH"; }

# _rfa_describe <pid> — everything needed to tell a real leak from a false
# positive, WITHOUT re-running CI. Two fixes have now been attempted on this
# assertion (#1943 zombies, and the identity check above) and each time the
# failure output was a bare count, which is why the second attempt was still a
# guess. A count that cannot be explained is not evidence.
_rfa_describe() {
    local _p="$1"
    printf '    pid=%s state=%s ppid=%s cmd=[%s]\n' "$_p" \
        "$(ps -o state= -p "$_p" 2>/dev/null | tr -d ' ' || echo '?')" \
        "$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || echo '?')" \
        "$( { tr '\0' ' ' < "$_RFA_PROC/$_p/cmdline"; } 2>/dev/null || echo '<unreadable>')" >&2
    # WHY it was counted, not just that it was (#2020). A failed REDIRECT is
    # reported by the shell, not by tr, so `2>/dev/null` on the command alone
    # leaks a raw "No such file or directory" line from this very function —
    # which is exactly what the last failure printed. proc-identity.sh already
    # gets this right and documents it as #1631's class; this copy did not.
    printf '    classification=%s\n' "${PROC_IDENTITY_REASON:-<none>}" >&2
}

_st=""
leftover=0
# #2029: 15s, not 2s. The leak this hunts is a 60s stub that ignored its
# signal; no plausible load makes that finish inside 15s, so widening cannot
# hide one. What 2s DID catch was a stub still shutting down when a fixed
# wall-clock bound expired — a false red, on ubuntu CI, on diffs that could not
# reach this code. The synchronous-abort discrimination does not ride on this
# number any more (#1975 moved it to an elapsed_ms floor, which load can only
# push in the safe direction), so the window is free to be generous.
deadline_ns=$(( $(date +%s%N) + 15000000000 ))
while [[ $(date +%s%N) -lt $deadline_ns ]]; do
    leftover=0
    if [[ -f "$PID_FILE" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            # IDENTITY, not liveness (#1942 follow-up). `kill -0` answers "does
            # something own this PID", which is NOT the question. Two ways that
            # differs from "my stub is still running":
            #   - PID REUSE. The stub file is appended to (`>> $PID_FILE`), so a
            #     retried spawn leaves earlier PIDs in it. Once such a PID is
            #     reaped the kernel is free to hand the number to an unrelated
            #     process, and on a loaded CI runner it does. `kill -0` then
            #     succeeds and `ps -o state=` says `S`, so a stranger is counted
            #     as OUR leftover. That is a false FAIL with no bug behind it.
            #   - ZOMBIES, the #1942 case, still handled — see below.
            # /proc is safe here: this whole file is `skip_unless_platform linux`.
            if ! _rfa_is_my_stub "$p"; then
                continue
            fi
            if kill -0 "$p" 2>/dev/null; then
                # `kill -0` SUCCEEDS for a zombie: a process that has exited but
                # has not been reaped still owns its PID slot and still answers.
                # Counting those made this assertion flaky (#1942). When the
                # driver exits the stub is reparented to PID 1, and how fast
                # PID 1 reaps is its scheduling decision — under an ubuntu CI
                # runner's load that is not reliably inside a tight window.
                #
                # It presents as "ubuntu-only" ONLY because this whole file is
                # `skip_unless_platform linux` (line 51) — macOS never runs it,
                # so there is no macOS evidence either way. Do not read the
                # asymmetry as a platform difference in reaping.
                #
                # This comment previously said the window must NOT be relaxed,
                # because it was the only thing distinguishing a synchronous
                # abort from the pre-#905 backstop (`{ sleep 1 && kill -KILL; } &`).
                # That was true, and it made the window unfixable: it carried
                # both the leak check and the backstop check, and the two want
                # opposite things — generous for load-tolerance, tight for
                # discrimination.
                #
                # #1975 split them. Assertion (1b) discriminates on an
                # elapsed_ms FLOOR: the handler cannot return before its own 1s
                # watchdog fires, whereas the disowned backstop returned in
                # ~0ms. Load can only push wall-clock UP, so that floor cannot
                # be faked by a loaded runner — the property this window never
                # had. Widening the window is now safe, and #906's regression
                # is still caught, by (1b).
                # `|| _st="Z"` is NOT cosmetic. Under `set -euo pipefail`, if the process
                # exits between the `kill -0` above and this `ps`, the pipeline returns
                # non-zero, the assignment fails, and set -e kills the whole FILE —
                # silently, because stderr is redirected. Absorbing it routes a
                # now-dead process through the Z branch, which is what it is.
                _st="$(ps -o state= -p "$p" 2>/dev/null | tr -d ' ')" || _st="Z"
                case "$_st" in
                    Z*) : ;;                                  # already dead
                    *)  leftover=$(( leftover + 1 )) ;;
                esac
            fi
        done < "$PID_FILE"
    fi
    [[ $leftover -eq 0 ]] && break
    sleep 0.05
done
# Best-effort cleanup of any still-alive stubs so the suite doesn't accrue
# zombies, AFTER the assertion read its final count.
if [[ -f "$PID_FILE" ]]; then
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        kill -KILL "$p" 2>/dev/null || true
    done < "$PID_FILE"
fi
# Explain a non-zero count before asserting on it, so the next occurrence
# arrives with its own diagnosis attached.
if [[ $leftover -ne 0 && -f "$PID_FILE" ]]; then
    echo "  DIAGNOSTIC: ${leftover} leftover stub(s) after the 2s reap window:" >&2
    # #2029: describe EVERY pid, not only ones still classified as ours. The
    # guard used to be `_rfa_is_my_stub "$p" && _rfa_describe "$p"`, so a stub
    # that was counted during the poll and then exited produced a header and no
    # lines — a bare count, on the one run where the diagnosis was most needed.
    # "Counted during the poll, gone by the time we looked" is the most useful
    # thing that could be said there, and the guard was suppressing exactly it.
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        _rfa_is_my_stub "$p" || true          # sets PROC_IDENTITY_REASON
        _rfa_describe "$p"
    done < "$PID_FILE"
fi
assert_eq "no leftover stub-claude processes after abort" "0" "$leftover"

# (3) The driver actually saw rc=130 (or any signal exit) — i.e. the loop
#     returned a signal-class exit code (130), not a generic failure. If the
#     watchdog killed it instead, loop.rc may be missing.
if [[ -f "$TEST_TEMP_DIR/loop.rc" ]]; then
    rc_line="$(cat "$TEST_TEMP_DIR/loop.rc" 2>/dev/null || true)"
    if [[ "$rc_line" == "rc=130" ]]; then
        assert_pass "route_to_model_loop returned rc=130 (signal exit)"
    else
        assert_fail "route_to_model_loop returned rc=130" "got: '$rc_line'"
    fi
else
    assert_fail "driver wrote loop.rc" "missing — driver killed by watchdog (abort regressed)"
fi

if [[ "${KEEP_TMP:-0}" == "1" || $FAIL -gt 0 ]]; then
    echo "  KEEPTEMP=$TEST_TEMP_DIR" >&2
else
    cleanup_test_env
fi
print_test_results
exit $((FAIL > 0))
