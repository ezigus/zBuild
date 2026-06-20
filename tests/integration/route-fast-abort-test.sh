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
# stub dead within 500ms of loop-return, encoding that synchronous contract.
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
# tree safely. On hosts without setsid (e.g. plain macOS without util-linux)
# the implementation falls back to the per-PID kill from Wave 8 (#612),
# which does not satisfy the 2.5s budget by design — the kernel still has
# to wait for the trap-ignoring child to consume the eventual SIGKILL the
# 1s-delayed backstop sends to the bash subshell, but the orphaned claude
# is not in a kill-able PG. CI (ubuntu-latest) ships util-linux setsid, so
# this test's contract is enforced there. Skip locally on no-setsid hosts
# with a clear marker so devs aren't confused.
if ! command -v setsid >/dev/null 2>&1 || ! setsid -w true >/dev/null 2>&1; then
    echo "  SKIP: setsid -w unavailable on this host — Wave 15-G PG-kill"
    echo "        path not exercisable. CI (ubuntu-latest) covers it."
    cleanup_test_env
    print_test_results
    exit 0
fi

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
MARKER="ZB-W15G-MARKER-$$-$(date +%s)"

# Stub claude: trap-and-ignore SIGTERM/INT, sleep long. Records its PID
# into a file so we can verify it was actually reaped.
mkdir -p "$TEST_TEMP_DIR/bin"
PID_FILE="$TEST_TEMP_DIR/stub-claude.pid"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
# Marker arg so pgrep can find us by cmdline: $MARKER
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
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export ZB_STUB_MARKER="$MARKER"

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

# (2) No stub-claude process from this driver is still running. #905 made the
#     abort SYNCHRONOUS — _route_loop_on_signal does not return until the child
#     tree has been SIGKILLed and reaped, so by the time the driver exited (the
#     `wait "$DRV_PID"` above returned) the stub is already dead. We allow only
#     a short 500ms reap window for the kernel to clear the reparented zombie's
#     PID slot — NOT a multi-second wait for a detached backstop to fire. If the
#     stub is still alive after 500ms the abort leaked (the pre-#905 bug: the
#     `{ sleep 1 && kill -KILL; } &` backstop raced the caller's exit).
#     Millisecond-precise deadline (not integer `date +%s`, whose second-
#     granularity made the old window race between ~1s and ~2s under load).
leftover=0
deadline_ns=$(( $(date +%s%N) + 500000000 ))
while [[ $(date +%s%N) -lt $deadline_ns ]]; do
    leftover=0
    if [[ -f "$PID_FILE" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if kill -0 "$p" 2>/dev/null; then
                leftover=$(( leftover + 1 ))
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
