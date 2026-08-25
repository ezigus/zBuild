#!/usr/bin/env bash
# tests/unit/write-boundary-degraded-test.sh
# Unit tests for the write-boundary DEGRADED-FENCE reporting (#1956, from #1953).
#
# SPEC-1[change]: a sweep whose find fails records path, rc and stderr instead of
#                 reporting a clean dispatch.
# SPEC-2[change]: the failure is emitted as stage.write_boundary.sweep_failed and
#                 registered in config/event-schema.json.
# SPEC-3[guard]:  a partial find failure still yields every candidate find could
#                 read — the reason this is not fixed by failing closed.
# SPEC-4[change]: a snapshot that could not be taken is reported, not swallowed.
#
# Split from write-boundary-sweep-test.sh to keep both files under the 500-line
# limit in CLAUDE.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "write-boundary degraded reporting — SPEC-1/2/3/4 (#1956)"
setup_test_env "write-boundary-degraded"

_WB_EVENTS=()
emit_event() { _WB_EVENTS+=("$*"); }

WB_LIB="$REPO_ROOT/core/pipeline/write-boundary.sh"
# shellcheck source=../../core/pipeline/write-boundary.sh
source "$WB_LIB"

# ─── SPEC-1/2/3/4: a sweep that could not look must not report "clean" ──────
# `find … 2>/dev/null || true`, consumed through a command substitution,
# discarded the status twice and the stderr once. A sweep that FAILED and a
# sweep that found nothing were the same observation, and the fence reported a
# clean dispatch without having looked. Found while hunting the ubuntu-only
# SPEC-4 flake (#1953); true on every platform (#1956).
# CHANGE: fails at baseline (the failure was unobservable by construction).

_SW_ROOT="$TEST_TEMP_DIR/sweep-fail"
_SW_LOG="$TEST_TEMP_DIR/sweep-fail.log"
mkdir -p "$_SW_ROOT/readable" "$_SW_ROOT/locked"
_SW_MARKER="$TEST_TEMP_DIR/sweep-fail.marker"
touch "$_SW_MARKER"
# Wait for the stamp to move before writing, or on Linux these files share the
# marker's tick and `find -newer` skips them — this fixture hit the very defect
# SPEC-9 fixes, and failed on ubuntu while passing on macOS.
_wb_clock_advance_past "$_SW_MARKER"
# Both files are newer than the marker; one of them sits where find cannot look.
printf 'x\n' > "$_SW_ROOT/readable/seen.txt"
printf 'x\n' > "$_SW_ROOT/locked/unseen.txt"
_SW_WATCH="$TEST_TEMP_DIR/sweep-fail-watch.txt"
printf '%s\n' "$_SW_ROOT" > "$_SW_WATCH"
chmod 000 "$_SW_ROOT/locked"

_sw_out="$(ZBUILD_WRITE_BOUNDARY_WATCH="$_SW_WATCH" ZBUILD_WRITE_BOUNDARY_LOG="$_SW_LOG" \
    write_boundary_sweep "$_SW_MARKER" 2>"$TEST_TEMP_DIR/sweep-fail.err")"
_sw_err="$(cat "$TEST_TEMP_DIR/sweep-fail.err" 2>/dev/null || true)"
_sw_log="$(cat "$_SW_LOG" 2>/dev/null || true)"

assert_contains "[SPEC-1] a failed sweep says so on stderr, naming the path" \
    "$_sw_err" "$_SW_ROOT"
assert_contains "[SPEC-1] the stderr diagnostic carries find's exit status" \
    "$_sw_err" "rc="
assert_contains "[SPEC-1] the failure reaches the ZBUILD_WRITE_BOUNDARY_LOG sink" \
    "$_sw_log" "sweep_failed"

# SPEC-3 is the reason this is not fixed by failing closed. find returns
# non-zero on a PARTIAL error while still enumerating everything it could read,
# and on a real machine `find $HOME -maxdepth 1` hits permission-denied on other
# users' entries routinely. Treating rc!=0 as a violation would resolve nearly
# every dispatch to broken — terminal per verdict.sh:648-651. The defect is that
# the failure is invisible, not that it is tolerated.
assert_contains "[SPEC-3] a partial failure still yields the candidates find could read" \
    "$_sw_out" "$_SW_ROOT/readable/seen.txt"

chmod 755 "$_SW_ROOT/locked"

# GUARD: the diagnostic must not fire on a healthy sweep — a fence that cries
# wolf on every dispatch teaches an operator to ignore it.
: > "$_SW_LOG"
_sw_ok_err="$(ZBUILD_WRITE_BOUNDARY_WATCH="$_SW_WATCH" ZBUILD_WRITE_BOUNDARY_LOG="$_SW_LOG" \
    write_boundary_sweep "$_SW_MARKER" 2>&1 >/dev/null)"
assert_eq "[SPEC-1] a healthy sweep emits no failure diagnostic" "" "$_sw_ok_err"
assert_eq "[SPEC-1] a healthy sweep writes nothing to the sink" \
    "" "$(cat "$_SW_LOG" 2>/dev/null || true)"

# SPEC-2: the degraded fence is queryable in the durable event stream, not just
# in scrollback that most integration tests discard.
_WB_EVENTS=()
chmod 000 "$_SW_ROOT/locked"
ZBUILD_WRITE_BOUNDARY_WATCH="$_SW_WATCH" \
    write_boundary_sweep "$_SW_MARKER" >/dev/null 2>&1 || true
chmod 755 "$_SW_ROOT/locked"
_sw_ev=""
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.sweep_failed"* ]] && _sw_ev="$_ev"
done
assert_contains "[SPEC-2] a failed sweep emits stage.write_boundary.sweep_failed" \
    "$_sw_ev" "stage.write_boundary.sweep_failed"

if jq -e '.known_types | index("stage.write_boundary.sweep_failed")' \
     "$REPO_ROOT/config/event-schema.json" >/dev/null 2>&1; then
    assert_pass "[SPEC-2] the event type is registered in event-schema.json"
else
    assert_fail "[SPEC-2] the event type is registered in event-schema.json" \
        "stage.write_boundary.sweep_failed missing from known_types"
fi

# SPEC-4: a snapshot that was never taken must not read as a clean dispatch
# either — write_boundary_mark swallowed both its mkdir and its touch failure,
# and write_boundary_check returns 0 before sweeping when the marker is absent.
_MK_LOG="$TEST_TEMP_DIR/mark-fail.log"
_MK_BLOCKED="$TEST_TEMP_DIR/mark-blocked"
mkdir -p "$_MK_BLOCKED"
chmod 500 "$_MK_BLOCKED"
ZBUILD_WRITE_BOUNDARY_LOG="$_MK_LOG" \
    write_boundary_mark "$_MK_BLOCKED/pipeline-state.json" 2>"$TEST_TEMP_DIR/mark-fail.err" || true
chmod 755 "$_MK_BLOCKED"
_mk_err="$(cat "$TEST_TEMP_DIR/mark-fail.err" 2>/dev/null || true)$(cat "$_MK_LOG" 2>/dev/null || true)"
assert_contains "[SPEC-4] a snapshot that could not be taken is reported, not swallowed" \
    "$_mk_err" "mark"

# All three channels, not two: the sweep-failure path asserts the event stream
# and this one did not, leaving emit_event untested for mark failures.
_mk_ev=""
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.mark_failed"* ]] && _mk_ev="$_ev"
done
assert_contains "[SPEC-4] the mark failure reaches the event stream too" \
    "$_mk_ev" "stage.write_boundary.mark_failed"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
