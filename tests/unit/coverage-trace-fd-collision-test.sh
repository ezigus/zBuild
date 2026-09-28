#!/usr/bin/env bash
# Coverage tracing must not hijack a file descriptor the engine redirects.
#
# `--coverage-trace` exports BASH_XTRACEFD so every traced child writes its
# xtrace to a private fd instead of stderr. That fd was 9 — which is this repo's
# standard `flock` descriptor:
#
#   core/state/atomic.sh          ) 9>"$lock_file"
#   core/event-bus/event-bus.sh   ) 9>"${ZBUILD_EVENTS_JSONL}.lock"   (and .db)
#   core/router/route.sh          ) 9>"${_ledger_file}.lock"
#   plugins/…/github-labels       exec 9>"${f}.lock"
#   plugins/tool/cache-gh-actions ) 9>"$lock_file"
#
# A subshell that redirects `9>lockfile` therefore re-points BASH_XTRACEFD at
# the LOCK FILE, and bash writes the whole trace of that critical section into
# it. Measured directly: with BASH_XTRACEFD=9 the trace landed in the lock file
# (65 bytes, stderr empty); without it, in stderr (65 bytes, lock file empty).
#
# Three consequences, none of which look like "tracing is slow":
#   * the lock file fills with trace data — anything reading or sizing it sees garbage
#   * the I/O happens INSIDE the critical section, while flock is held
#   * so every other process waiting on that lock waits for it
#
# The event bus locks on EVERY emit, twice. That is the amplification that made
# the Coverage job time out on a test whose own assertions all passed — it was
# never a timing margin, it was lock contention manufactured by the tracer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "coverage tracing does not collide with an engine fd"
setup_test_env "coverage-trace-fd-collision"

# From the EXPORT, not from prose. A `grep BASH_XTRACEFD=[0-9]+` matches the
# explanatory comment above it first, so the test would read the documented fd
# rather than the one actually exported — and a mutation of the export alone
# would not redden it. Caught by mutation-checking this file.
_TRACE_FD="$(grep -oE '^[[:space:]]*export[[:space:]]+BASH_XTRACEFD=[0-9]+' \
    "$REPO_ROOT/scripts/run-tests.sh" | head -1 | grep -oE '[0-9]+$' || true)"
assert_gt "[SPEC-1] run-tests.sh names a trace fd" "${_TRACE_FD:-0}" "0"

# ─── SPEC-1: behavioural — a locked section does not capture the trace ──────
# Mirrors core/state/atomic.sh's idiom exactly.
# Locks on fd 9 — the engine's ACTUAL lock descriptor — not on $_TRACE_FD.
# Locking on the trace fd would be self-fulfilling: the probe would construct
# the very collision it claims to detect, and could never pass whatever fd the
# tracer used.
_ENGINE_LOCK_FD=9
_probe="$TEST_TEMP_DIR/locked.sh"
cat > "$_probe" <<PROBE
#!/usr/bin/env bash
(
    flock $_ENGINE_LOCK_FD 2>/dev/null || true
    echo ran
) ${_ENGINE_LOCK_FD}>"\$1"
PROBE
printf 'set -x\n' > "$TEST_TEMP_DIR/bashenv"
_lock="$TEST_TEMP_DIR/probe.lock"
_tracefile="$TEST_TEMP_DIR/probe.trace"
: > "$_lock"; : > "$_tracefile"
# The outer invocation must OPEN the trace fd, exactly as run-tests.sh does
# (`bash "$1" </dev/null 3>/dev/null 9>"$3"`). Without it bash finds the fd
# closed and silently disables tracing — the probe then passes because nothing
# was traced at all, which is a false green measuring the harness. That is the
# same shape as the stub-before-source defect this repo has now hit four times.
# eval, because a redirection target fd cannot come from a variable in place —
# `"$fd>file"` is parsed as a word, not a redirect, and the trace fd is then
# never opened. The guard below is what caught that.
eval "PS4='TRACE:\${LINENO}:' BASH_XTRACEFD=\"\$_TRACE_FD\" \
    BASH_ENV=\"\$TEST_TEMP_DIR/bashenv\" \
    bash \"\$_probe\" \"\$_lock\" >/dev/null 2>/dev/null ${_TRACE_FD}>\"\$_tracefile\"" || true
# Guard first: if nothing was traced, the assertion below proves nothing.
assert_gt "[SPEC-1] the probe actually produced trace output" \
    "$(( $(wc -c < "$_tracefile" | tr -d ' ') + $(wc -c < "$_lock" | tr -d ' ') ))" "0"
assert_eq "[SPEC-1] a section locking on the engine's fd 9 does not fill its lock file" \
    "0" "$(wc -c < "$_lock" | tr -d ' ')"

# ─── SPEC-1b: the fd is one bash will actually ACCEPT ───────────────────────
# Bash validates BASH_XTRACEFD and REJECTS anything outside 3-9 with
#   bash: BASH_XTRACEFD: 21: invalid value for trace file descriptor
# then falls back to stderr. That failure is silent in aggregate: tracing still
# "works", the trace file just never fills, and coverage reads near-zero for
# everything. A first pass at this fix picked fd 21 precisely because it looked
# unused — and it disabled the tracer outright. "Not colliding" was never the
# whole requirement; "valid" is the other half, and only this assertion carries
# it.
_fd_probe_out="$TEST_TEMP_DIR/fdvalid.out"
_fd_probe_err="$TEST_TEMP_DIR/fdvalid.err"
eval "PS4='TRACE:' BASH_XTRACEFD=\"\$_TRACE_FD\" BASH_ENV=\"\$TEST_TEMP_DIR/bashenv\" \
    bash -c 'echo probe' ${_TRACE_FD}>\"\$_fd_probe_out\" >\"\$_fd_probe_err\" 2>&1" || true
_fd_rejected=0
grep -q 'invalid value for trace file descriptor' "$_fd_probe_out" "$_fd_probe_err" 2>/dev/null \
    && _fd_rejected=1
assert_eq "[SPEC-1b] bash accepts the trace fd ($_TRACE_FD) rather than falling back to stderr" \
    "0" "$_fd_rejected"
# `|| true`, not `|| echo 0`: grep -c already prints the count, so `|| echo 0`
# emits "0\n0" on no-match (scripts/lib/lint-grep-c.sh enforces this).
# And >0 rather than ==1: the exact line count depends on how much BASH_ENV
# itself traces, which is not the thing under test.
_fd_trace_lines="$(grep -c 'TRACE:' "$_fd_probe_out" 2>/dev/null || true)"
assert_gt "[SPEC-1b] the trace reaches the trace fd, not stderr" \
    "${_fd_trace_lines:-0}" "0"

# ─── SPEC-2: static — the trace fd is not one the engine redirects ──────────
# The durable form: a future `N>` on the trace fd re-creates the defect, and a
# behavioural probe only covers the idiom it happens to mirror.
# run-tests.sh is excluded: it is the TRACER, and its own `21>"$3"` is the
# wiring under test, not a collision with it. Everything else is engine code
# whose redirects the tracer must stay clear of.
_USED_FDS="$(grep -rhoE '\b(exec )?[0-9]+>' \
    "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" 2>/dev/null \
    --exclude=run-tests.sh \
    | grep -oE '[0-9]+' | sort -un | { grep -vE '^[0-2]$' || true; })"
_collides=0
while IFS= read -r _fd; do
    [[ -z "$_fd" ]] && continue
    [[ "$_fd" == "$_TRACE_FD" ]] && _collides=1
done <<< "$_USED_FDS"
if [[ $_collides -eq 0 ]]; then
    assert_pass "[SPEC-2] the trace fd ($_TRACE_FD) is not redirected anywhere in the engine"
else
    assert_fail "[SPEC-2] the trace fd ($_TRACE_FD) is not redirected anywhere in the engine" \
        "engine redirects fds: $(tr '\n' ' ' <<< "$_USED_FDS")"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
