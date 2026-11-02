#!/usr/bin/env bash
# tests/unit/event-bus-trap-reentry-test.sh — an emit from a signal trap does
# not wait on the events lock its own shell holds (#2456, ADR-065 §5).
#
# Why: since #2407 eb_emit_event takes the lock in the caller's shell (a brace
# group with `9>lock`, no fork). A TERM that lands while that group holds the
# lock runs the trap right there; the abort trap's own emits then opened the
# lock again and waited 5 s each on their own shell, and gave up — the abort
# took 5 s per emit and recorded no pipeline.aborted. On Ubuntu CI that failed
# runner-release-exit-paths SPEC-5 and the sigterm tests now and then.
#
# A stub flock first on PATH takes the real lock, then sends TERM to the shell
# that called it, so the TERM always lands while the lock is held.
#
# T1 [change] the trap's emit returns at once (well under the 5 s wait)
# T2 [change] ...and its event is in events.jsonl
# T3 [guard]  an ordinary emit still takes the lock
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "an emit from a signal trap does not wait on its own lock (#2456)"
setup_test_env "eb-trap-reentry"

REAL_FLOCK="$(command -v flock 2>/dev/null || true)"
if [[ -z "$REAL_FLOCK" ]]; then
    # No flock: the bus writes without a lock, and there is nothing to wait on.
    SKIP=$((SKIP + 1))
    echo "  SKIP: no flock on this host" >&2
    cleanup_test_env
    print_test_results
    exit 0
fi

STUB="$TEST_TEMP_DIR/stub"; mkdir -p "$STUB"
CALLS="$TEST_TEMP_DIR/flock-calls"
cat > "$STUB/flock" <<EOF
#!/usr/bin/env bash
printf 'x\n' >> "$CALLS"
"$REAL_FLOCK" "\$@" || exit \$?
if [[ -n "\${SEND_TERM_TO:-}" && ! -e "\$SEND_TERM_TO.sent" ]]; then
    : > "\$SEND_TERM_TO.sent"
    kill -TERM "\$(cat "\$SEND_TERM_TO")"
fi
exit 0
EOF
chmod +x "$STUB/flock"

# _run <dir> <send-term:0|1> — a shell that emits once, with an abort trap that
# emits pipeline.aborted and says how long that took.
_run() {
    local d="$1"; mkdir -p "$d"
    local pidf=""; [[ "$2" == 1 ]] && pidf="$d/pid"
    ZBUILD_EVENTS_DIR="$d" ZBUILD_EVENTS_JSONL="$d/events.jsonl" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    PATH="$STUB:$PATH" SEND_TERM_TO="$pidf" \
    timeout 30 bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh" 2>/dev/null
        source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"
        [[ -n "$SEND_TERM_TO" ]] && printf "%s" "$$" > "$SEND_TERM_TO"
        trap '\''t0=$EPOCHSECONDS; eb_emit_event pipeline.aborted reason=sigterm; echo "TRAP_SECONDS=$((EPOCHSECONDS - t0))"; exit 1'\'' TERM
        eb_emit_event pipeline.start
        echo "NO_TRAP"
    ' 2>/dev/null
}

print_test_section "T1-T2: a TERM while the lock is held"
_out="$(_run "$TEST_TEMP_DIR/t1" 1)"
_secs="$(sed -n 's/^TRAP_SECONDS=//p' <<< "$_out")"
assert_contains "[T1] the trap ran" "$_out" "TRAP_SECONDS="
if [[ -n "$_secs" && "$_secs" -lt 2 ]]; then
    assert_pass "[T1] the trap's emit returned at once (${_secs}s)"
else
    assert_fail "[T1] the trap's emit returned at once" "took ${_secs:-?}s — it waited on its own shell's lock"
fi
assert_eq "[T2] pipeline.aborted is in events.jsonl" "1" \
    "$(grep -c '"type":"pipeline.aborted"' "$TEST_TEMP_DIR/t1/events.jsonl" 2>/dev/null || true)"

print_test_section "T3: an ordinary emit takes the lock"
: > "$CALLS"
_out3="$(_run "$TEST_TEMP_DIR/t3" 0)"
assert_contains "[T3] the emit finished" "$_out3" "NO_TRAP"
assert_eq "[T3] it took the lock once" "1" "$(grep -c x "$CALLS" 2>/dev/null || true)"
assert_eq "[T3] its event is written" "1" \
    "$(grep -c '"type":"pipeline.start"' "$TEST_TEMP_DIR/t3/events.jsonl" 2>/dev/null || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
