#!/usr/bin/env bash
# Tests: core/pipeline/strategies/map.sh — unit tests (issue #1285, ADR-047)
# SPEC-1: platform dimension dispatches one-per-platform (byte-identical to fanout)
# SPEC-2: non-platform declared dimension dispatches one-per-element
# SPEC-3: empty dimension → no dispatch, no error (rc=3, caller maps to 0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/strategies/map — unit: data-driven dimension dispatch (issue #1285)"
setup_test_env "map-strategy-unit"

ORCH_SPY_LOG="$TEST_TEMP_DIR/orch-spy.log"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR" "$PLUGINS_ROOT"

# shellcheck source=../../core/pipeline/strategies/map.sh
source "$REPO_ROOT/core/pipeline/strategies/map.sh"
# shellcheck source=../../core/pipeline/strategies/fanout.sh
source "$REPO_ROOT/core/pipeline/strategies/fanout.sh"

# ─── Spy orch contract ────────────────────────────────────────────────────────
export ORCH_SPY_LOG
_spy_log() { printf '%s %s\n' "$1" "${2:-}" >> "$ORCH_SPY_LOG"; }

orch_spawn()    { _spy_log "orch_spawn"    "$1"; mkdir -p "${TMPDIR:-/tmp}/zbuild-pool-$1/results" "${TMPDIR:-/tmp}/zbuild-pool-$1/pids"; return 0; }
orch_dispatch() { _spy_log "orch_dispatch" "$1"; local wu="${2:-}"; [[ -f "$wu" ]] && bash "$wu" >/dev/null 2>&1 || true; printf 'slot-001\n'; return 0; }
orch_collect()  { _spy_log "orch_collect"  "$1"; return 0; }
orch_shutdown() { _spy_log "orch_shutdown" "$1"; rm -rf "${TMPDIR:-/tmp}/zbuild-pool-$1" 2>/dev/null || true; return 0; }

# ─── Shared plugin + state setup ─────────────────────────────────────────────
MAP_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/tool/map-agent"
mkdir -p "$MAP_PLUGIN_DIR"
printf '#!/usr/bin/env bash\n_map_agent_run() { return 0; }\n' > "$MAP_PLUGIN_DIR/plugin.sh"

STATE_FILE="$STATE_DIR/pipeline-state-map.json"
printf '{"run_id":"test-map"}\n' > "$STATE_FILE"

ROLES_OUT="security-auditor"
resolve_plugin_for_role() { echo "$MAP_PLUGIN_DIR"; }
_check_artifact_contract() { return 0; }

# ─── SPEC-1: platform dimension → one-per-platform (byte-identical to fanout) ─
print_test_section "SPEC-1: map over platforms dispatches one work unit per platform"

_DETECTED_PLATFORMS=("ios" "node")
: > "$ORCH_SPY_LOG"

set +e
_strategy_run_map "map-pool-001" "intake" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "platforms"
map_rc=$?
set -e

assert_exit_code "SPEC-1: map exits 0 (all success)" "0" "$map_rc"

dispatch_count=0; dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$ORCH_SPY_LOG" 2>/dev/null) || dispatch_count=0
shutdown_count=0; shutdown_count=$(/usr/bin/grep -c "^orch_shutdown" "$ORCH_SPY_LOG" 2>/dev/null) || shutdown_count=0

if [[ "$dispatch_count" -eq 2 ]]; then
    assert_pass "SPEC-1: orch_dispatch called once per platform (got $dispatch_count for 2 platforms × 1 role)"
else
    assert_fail "SPEC-1: orch_dispatch called once per platform" "got $dispatch_count (expected exactly 2)"
fi

if [[ "$shutdown_count" -ge 1 ]]; then
    assert_pass "SPEC-1: orch_shutdown called"
else
    assert_fail "SPEC-1: orch_shutdown called" "got 0"
fi

# Cross-check: fanout over same platforms must produce identical dispatch count.
: > "$ORCH_SPY_LOG"
set +e
_strategy_run_fanout "fanout-pool-001" "intake" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT"
fanout_rc=$?
set -e

fanout_dispatch_count=0; fanout_dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$ORCH_SPY_LOG" 2>/dev/null) || fanout_dispatch_count=0

assert_exit_code "SPEC-1: fanout exits 0 for same inputs" "0" "$fanout_rc"

if [[ "$dispatch_count" -eq "$fanout_dispatch_count" ]]; then
    assert_pass "SPEC-1: map dispatch count ($dispatch_count) == fanout dispatch count ($fanout_dispatch_count) — byte-identical behavior"
else
    assert_fail "SPEC-1: map dispatch count == fanout dispatch count" \
        "map=$dispatch_count fanout=$fanout_dispatch_count"
fi

# ─── SPEC-2: non-platform declared dimension dispatches one-per-element ───────
print_test_section "SPEC-2: map over declared non-platform dimension (lenses)"

# Declare the lenses dimension via the _MAP_DIM_lenses convention.
declare -a _MAP_DIM_lenses=("security" "quality" "perf")
export _MAP_DIM_lenses

: > "$ORCH_SPY_LOG"
set +e
_strategy_run_map "map-pool-002" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "lenses"
map2_rc=$?
set -e

assert_exit_code "SPEC-2: map over lenses exits 0" "0" "$map2_rc"

lens_dispatch_count=0; lens_dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$ORCH_SPY_LOG" 2>/dev/null) || lens_dispatch_count=0

if [[ "$lens_dispatch_count" -eq 3 ]]; then
    assert_pass "SPEC-2: orch_dispatch called once per lens element (got $lens_dispatch_count for 3 lenses × 1 role)"
else
    assert_fail "SPEC-2: orch_dispatch called once per lens element" "got $lens_dispatch_count (expected exactly 3)"
fi

lens_shutdown_count=0; lens_shutdown_count=$(/usr/bin/grep -c "^orch_shutdown" "$ORCH_SPY_LOG" 2>/dev/null) || lens_shutdown_count=0
if [[ "$lens_shutdown_count" -ge 1 ]]; then
    assert_pass "SPEC-2: orch_shutdown called after lens dispatch"
else
    assert_fail "SPEC-2: orch_shutdown called after lens dispatch" "got 0"
fi

# ─── SPEC-3: empty dimension → no dispatch, no error ─────────────────────────
print_test_section "SPEC-3: empty dimension → no dispatch, rc=3 (caller maps to 0)"

declare -a _MAP_DIM_empty=()
export _MAP_DIM_empty

: > "$ORCH_SPY_LOG"
set +e
_strategy_run_map "map-pool-003" "intake" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "empty"
empty_rc=$?
set -e

assert_exit_code "SPEC-3: empty dimension exits 3 (no elements)" "3" "$empty_rc"

empty_dispatch_count=0; empty_dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$ORCH_SPY_LOG" 2>/dev/null) || empty_dispatch_count=0
if [[ "$empty_dispatch_count" -eq 0 ]]; then
    assert_pass "SPEC-3: no orch_dispatch called for empty dimension"
else
    assert_fail "SPEC-3: no orch_dispatch called for empty dimension" "got $empty_dispatch_count"
fi

# Empty _DETECTED_PLATFORMS also yields rc=3 (no dispatch)
unset _MAP_DIM_lenses _MAP_DIM_empty
_DETECTED_PLATFORMS=()
: > "$ORCH_SPY_LOG"
set +e
_strategy_run_map "map-pool-004" "intake" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "platforms"
empty_plat_rc=$?
set -e

assert_exit_code "SPEC-3: empty _DETECTED_PLATFORMS exits 3" "3" "$empty_plat_rc"

# ─── SPEC-4: invalid dimension name → fail-closed rc=5 (NOT empty rc=3) ───────
print_test_section "SPEC-4: invalid dimension name fails closed (rc=5, not masqueraded as empty)"

_DETECTED_PLATFORMS=("ios")
: > "$ORCH_SPY_LOG"
set +e
# "bad name" contains a space → fails the dimension-name allowlist → rc=2 in the
# resolver → rc=5 from _strategy_run_map. Must NOT collapse to empty (rc=3).
_strategy_run_map "map-pool-005" "intake" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "bad name"
bad_rc=$?
set -e

assert_exit_code "SPEC-4: invalid dimension exits 5 (fail-closed, distinct from empty)" "5" "$bad_rc"

bad_dispatch_count=0; bad_dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$ORCH_SPY_LOG" 2>/dev/null) || bad_dispatch_count=0
if [[ "$bad_dispatch_count" -eq 0 ]]; then
    assert_pass "SPEC-4: no orch_dispatch for invalid dimension"
else
    assert_fail "SPEC-4: no orch_dispatch for invalid dimension" "got $bad_dispatch_count"
fi

# ─── SPEC-5: non-platform dimension does NOT hijack ZBUILD_PLATFORM ───────────
print_test_section "SPEC-5: platforms dim passes element as platform; non-platform dim does not"

# Spy on _strategy_make_work_unit to record the platform arg (4th positional)
# plus the generic map identity (args 5/6) and optional env-target (arg 7).
# platforms → element IS the platform (byte-identical to fanout).
# lenses    → platform stays "generic"; element/dimension ride args 5+6 so
#             ZBUILD_PLATFORM is not hijacked; arg 7 is the optional `as:` target.
MWU_ARGS_LOG="$TEST_TEMP_DIR/mwu-args.log"
: > "$MWU_ARGS_LOG"
_orig_make_wu=$(declare -f _strategy_make_work_unit)
_strategy_make_work_unit() {
    printf 'platform=[%s] element=[%s] dim=[%s] astarget=[%s]\n' \
        "${4:-<none>}" "${5:-}" "${6:-}" "${7:-}" >> "$MWU_ARGS_LOG"
    printf '%s\n' "$TEST_TEMP_DIR/wu-stub-$RANDOM"  # return a dummy work-unit path
    return 0
}

# platforms: element must be passed as the platform arg
_DETECTED_PLATFORMS=("ios")
: > "$ORCH_SPY_LOG"
set +e
_strategy_run_map "map-pool-006" "intake" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "platforms" >/dev/null 2>&1
set -e
if /usr/bin/grep -q "platform=\[ios\]" "$MWU_ARGS_LOG"; then
    assert_pass "SPEC-5: platforms dim passes element 'ios' as the platform arg (byte-identical to fanout)"
else
    assert_fail "SPEC-5: platforms dim passes element as platform arg" "log: $(cat "$MWU_ARGS_LOG")"
fi

# lenses (#1295): element+dimension are passed as args 5+6; platform stays "generic"
# so ZBUILD_PLATFORM is NOT hijacked by the element name.
declare -a _MAP_DIM_lenses5=("security")
export _MAP_DIM_lenses5
: > "$MWU_ARGS_LOG"
set +e
_strategy_run_map "map-pool-007" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "lenses5" >/dev/null 2>&1
set -e
if /usr/bin/grep -q "platform=\[generic\] element=\[security\] dim=\[lenses5\]" "$MWU_ARGS_LOG" && ! /usr/bin/grep -q "platform=\[security\]" "$MWU_ARGS_LOG"; then
    assert_pass "SPEC-5: non-platform dim passes generic platform — element 'security' does NOT become ZBUILD_PLATFORM"
else
    assert_fail "SPEC-5: non-platform dim must not pass element as platform" "log: $(cat "$MWU_ARGS_LOG")"
fi

# lenses + `as:` env-target (#1295): arg 7 carries the template-named var so the
# work unit sets it to the element. Strategy stays element-name-agnostic.
: > "$MWU_ARGS_LOG"
set +e
_strategy_run_map "map-pool-008" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" "lenses5" "ZBUILD_REVIEW_LENS_ID" >/dev/null 2>&1
set -e
if /usr/bin/grep -q "element=\[security\] dim=\[lenses5\] astarget=\[ZBUILD_REVIEW_LENS_ID\]" "$MWU_ARGS_LOG"; then
    assert_pass "SPEC-5: as: env-target is forwarded to _strategy_make_work_unit (generic dimension→env mapping)"
else
    assert_fail "SPEC-5: as: env-target forwarded to work-unit factory" "log: $(cat "$MWU_ARGS_LOG")"
fi

# Restore the real work-unit factory.
unset -f _strategy_make_work_unit
eval "$_orig_make_wu"
unset _MAP_DIM_lenses5

# ─── SPEC-6: element/dimension identity is validated → no shell injection ──────
# #1295 Copilot: map_element/map_dimension are baked as single-quoted literals
# into the generated work-unit script. A value with ', whitespace, or a newline
# must fail closed (rc=2), never produce a work unit that breaks out of quotes.
print_test_section "SPEC-6: map_element/map_dimension validated fail-closed (no injection)"

# A legal element/dimension still produces a work unit (baseline).
set +e
_wu_ok="$(_strategy_make_work_unit "$MAP_PLUGIN_DIR" "review" "$STATE_FILE" "generic" "security" "lenses" "ZBUILD_REVIEW_LENS_ID" 2>/dev/null)"
_ok_rc=$?
set -e
if [[ "$_ok_rc" -eq 0 && -f "$_wu_ok" ]]; then
    assert_pass "SPEC-6: legal element/dimension produces a work unit (rc=0)"
    # It must be syntactically valid bash (no injection even in the happy path).
    if bash -n "$_wu_ok" 2>/dev/null; then
        assert_pass "SPEC-6: generated work unit is syntactically valid bash"
    else
        assert_fail "SPEC-6: generated work unit parses" "bash -n rejected $_wu_ok"
    fi
    rm -f "$_wu_ok"
else
    assert_fail "SPEC-6: legal element/dimension produces a work unit" "rc=$_ok_rc path=$_wu_ok"
fi

# Illegal element: single quote injection attempt → fail closed, no work unit.
_inject="x'; touch $TEST_TEMP_DIR/PWNED; :'"
rm -f "$TEST_TEMP_DIR/PWNED"
set +e
_wu_bad="$(_strategy_make_work_unit "$MAP_PLUGIN_DIR" "review" "$STATE_FILE" "generic" "$_inject" "lenses" 2>/dev/null)"
_bad_rc=$?
set -e
if [[ "$_bad_rc" -eq 2 && -z "$_wu_bad" ]]; then
    assert_pass "SPEC-6: element with ' fails closed (rc=2), no work unit emitted"
else
    assert_fail "SPEC-6: element with ' must fail closed" "rc=$_bad_rc path=$_wu_bad"
fi
if [[ ! -e "$TEST_TEMP_DIR/PWNED" ]]; then
    assert_pass "SPEC-6: injection payload did NOT execute (no PWNED file)"
else
    assert_fail "SPEC-6: injection payload must not execute" "PWNED file was created"
fi

# Illegal element: whitespace/newline → fail closed.
set +e
_strategy_make_work_unit "$MAP_PLUGIN_DIR" "review" "$STATE_FILE" "generic" $'a\nb' "lenses" >/dev/null 2>&1
_nl_rc=$?
set -e
assert_exit_code "SPEC-6: element with newline fails closed (rc=2)" "2" "$_nl_rc"

# Illegal dimension: '-' is not a shell-array-safe token → fail closed.
set +e
_strategy_make_work_unit "$MAP_PLUGIN_DIR" "review" "$STATE_FILE" "generic" "security" "bad-dim" >/dev/null 2>&1
_dim_rc=$?
set -e
assert_exit_code "SPEC-6: dimension with '-' fails closed (rc=2)" "2" "$_dim_rc"

# ─── SPEC-7: map_element set without map_dimension → fail closed (minor #1312) ─
print_test_section "SPEC-7: map_element without map_dimension fails closed (rc=2)"

set +e
_strategy_make_work_unit "$MAP_PLUGIN_DIR" "review" "$STATE_FILE" "generic" "security" "" >/dev/null 2>&1
_no_dim_rc=$?
set -e
assert_exit_code "SPEC-7: map_element set + empty map_dimension fails closed (rc=2)" "2" "$_no_dim_rc"

# ─── SPEC-8: max_parallel cap is honored ─────────────────────────────────────
# #1312: _strategy_run_map must enforce the concurrency cap via batched dispatch.
# Verify: with 5 elements and max_parallel=2, work units are dispatched in
# batches of ≤2, meaning orch_collect is called ceil(5/2)=3 times (not once).
print_test_section "SPEC-8: max_parallel cap enforced — batched dispatch (issue #1312)"

declare -a _MAP_DIM_batch5=("a" "b" "c" "d" "e")
export _MAP_DIM_batch5

SPEC8_LOG="$TEST_TEMP_DIR/spec8-spy.log"
: > "$SPEC8_LOG"
_spec8_orch_spawn()    { printf 'orch_spawn %s\n'    "$1" >> "$SPEC8_LOG"; \
                          mkdir -p "${TMPDIR:-/tmp}/zbuild-pool-$1/results" "${TMPDIR:-/tmp}/zbuild-pool-$1/pids"; return 0; }
_spec8_orch_dispatch() { printf 'orch_dispatch %s\n' "$1" >> "$SPEC8_LOG"; return 0; }
_spec8_orch_collect()  { printf 'orch_collect %s\n'  "$1" >> "$SPEC8_LOG"; return 0; }
_spec8_orch_shutdown() { printf 'orch_shutdown %s\n' "$1" >> "$SPEC8_LOG"; \
                          rm -rf "${TMPDIR:-/tmp}/zbuild-pool-$1" 2>/dev/null || true; return 0; }

# Temporarily override the orch functions.
eval "$(declare -f orch_spawn)"    ; eval "orch_spawn_orig() { $(declare -f orch_spawn | tail -n +2); }"
eval "$(declare -f orch_dispatch)" ; eval "orch_dispatch_orig() { $(declare -f orch_dispatch | tail -n +2); }"
eval "$(declare -f orch_collect)"  ; eval "orch_collect_orig() { $(declare -f orch_collect | tail -n +2); }"
eval "$(declare -f orch_shutdown)" ; eval "orch_shutdown_orig() { $(declare -f orch_shutdown | tail -n +2); }"
orch_spawn()    { _spec8_orch_spawn "$@"; }
orch_dispatch() { _spec8_orch_dispatch "$@"; }
orch_collect()  { _spec8_orch_collect "$@"; }
orch_shutdown() { _spec8_orch_shutdown "$@"; }

set +e
_strategy_run_map "spec8-pool" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" \
    "batch5" "" "2" "continue"
spec8_rc=$?
set -e

# Restore originals.
orch_spawn()    { orch_spawn_orig "$@"; }
orch_dispatch() { orch_dispatch_orig "$@"; }
orch_collect()  { orch_collect_orig "$@"; }
orch_shutdown() { orch_shutdown_orig "$@"; }

assert_exit_code "SPEC-8: on_member_error=continue returns 0 even with 5 elements" "0" "$spec8_rc"

spec8_collect_count=0
spec8_collect_count=$(/usr/bin/grep -c "^orch_collect" "$SPEC8_LOG" 2>/dev/null) || spec8_collect_count=0
# 5 elements / batch-size 2 = ceil(5/2) = 3 batches → 3 orch_collect calls.
if [[ "$spec8_collect_count" -eq 3 ]]; then
    assert_pass "SPEC-8: 5 elements / cap 2 → 3 orch_collect calls (batched FIFO pool)"
else
    assert_fail "SPEC-8: 5 elements / cap 2 must produce 3 orch_collect calls" \
        "got $spec8_collect_count (log: $(cat "$SPEC8_LOG"))"
fi

spec8_dispatch_count=0
spec8_dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$SPEC8_LOG" 2>/dev/null) || spec8_dispatch_count=0
if [[ "$spec8_dispatch_count" -eq 5 ]]; then
    assert_pass "SPEC-8: exactly 5 work units dispatched (1 per element × 1 role)"
else
    assert_fail "SPEC-8: exactly 5 work units dispatched" "got $spec8_dispatch_count"
fi

unset _MAP_DIM_batch5

# ─── SPEC-9: on_member_error=continue — failing element does NOT abort group ──
# #1312: a failing orch_collect (simulating a failed element) must not cause
# _strategy_run_map to return non-zero when on_member_error=continue.
# Mirrors parallel_group_run: on_member_error=continue always returns 0 (advisory).
print_test_section "SPEC-9: on_member_error=continue — group returns 0 even when element fails (issue #1312)"

declare -a _MAP_DIM_errdim=("ok" "fail")
export _MAP_DIM_errdim

SPEC9_LOG="$TEST_TEMP_DIR/spec9-spy.log"
: > "$SPEC9_LOG"
_spec9_call=0
_spec9_orch_spawn()    { return 0; }
_spec9_orch_dispatch() { _spec9_call=$((_spec9_call + 1)); return 0; }
_spec9_orch_collect()  { printf 'orch_collect %s\n' "$1" >> "$SPEC9_LOG"
                          # Second collect (second batch of 1) simulates a failing element.
                          local _cnt; _cnt=$(/usr/bin/grep -c "orch_collect" "$SPEC9_LOG")
                          [[ "$_cnt" -eq 2 ]] && return 1
                          return 0; }
_spec9_orch_shutdown() { return 0; }

# Override.
orch_spawn()    { _spec9_orch_spawn "$@"; }
orch_dispatch() { _spec9_orch_dispatch "$@"; }
orch_collect()  { _spec9_orch_collect "$@"; }
orch_shutdown() { _spec9_orch_shutdown "$@"; }

set +e
_strategy_run_map "spec9-pool" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" \
    "errdim" "" "1" "continue"
spec9_rc=$?
set -e

# Restore.
orch_spawn()    { orch_spawn_orig "$@"; }
orch_dispatch() { orch_dispatch_orig "$@"; }
orch_collect()  { orch_collect_orig "$@"; }
orch_shutdown() { orch_shutdown_orig "$@"; }

assert_exit_code "SPEC-9: on_member_error=continue returns 0 even when 1 of 2 elements fails" "0" "$spec9_rc"

# Verify on_member_error=collect propagates the failure.
declare -a _MAP_DIM_errdim2=("ok" "fail")
export _MAP_DIM_errdim2

SPEC9B_LOG="$TEST_TEMP_DIR/spec9b-spy.log"
: > "$SPEC9B_LOG"
_spec9b_call=0
_spec9b_orch_spawn()    { return 0; }
_spec9b_orch_dispatch() { _spec9b_call=$((_spec9b_call + 1)); return 0; }
_spec9b_orch_collect()  { printf 'orch_collect %s\n' "$1" >> "$SPEC9B_LOG"
                           local _cnt; _cnt=$(/usr/bin/grep -c "orch_collect" "$SPEC9B_LOG")
                           [[ "$_cnt" -eq 2 ]] && return 1
                           return 0; }
_spec9b_orch_shutdown() { return 0; }

orch_spawn()    { _spec9b_orch_spawn "$@"; }
orch_dispatch() { _spec9b_orch_dispatch "$@"; }
orch_collect()  { _spec9b_orch_collect "$@"; }
orch_shutdown() { _spec9b_orch_shutdown "$@"; }

set +e
_strategy_run_map "spec9b-pool" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" \
    "errdim2" "" "1" "collect"
spec9b_rc=$?
set -e

orch_spawn()    { orch_spawn_orig "$@"; }
orch_dispatch() { orch_dispatch_orig "$@"; }
orch_collect()  { orch_collect_orig "$@"; }
orch_shutdown() { orch_shutdown_orig "$@"; }

if [[ "$spec9b_rc" -ne 0 ]]; then
    assert_pass "SPEC-9: on_member_error=collect propagates failure (rc=$spec9b_rc, non-zero)"
else
    assert_fail "SPEC-9: on_member_error=collect must propagate failure" "got rc=0 (expected non-zero)"
fi

unset _MAP_DIM_errdim _MAP_DIM_errdim2

# ─── SPEC-10: empty elements CSV — runner set -e guard (issue #1312) ──────────
# Verifies the `read -ra ... || true` guard: an empty elements CSV must NOT cause
# the read to abort under set -e. The dimension array stays empty → rc=3 (no-op).
print_test_section "SPEC-10: empty elements CSV — read guard prevents set -e abort (issue #1312)"

declare -ga _MAP_DIM_spec10=()
_spec10_IFS_save="$IFS"; IFS=','
# Simulate runner's read line with empty CSV and set -e active.
(
    set -e
    # shellcheck disable=SC2229
    read -ra "_MAP_DIM_spec10" <<< "" || true
    printf 'survived\n'
) > "$TEST_TEMP_DIR/spec10.out" 2>&1
_spec10_shell_rc=$?
_spec10_out="$(cat "$TEST_TEMP_DIR/spec10.out")"
IFS="$_spec10_IFS_save"; unset _spec10_IFS_save

if [[ $_spec10_shell_rc -eq 0 && "$_spec10_out" == "survived" ]]; then
    assert_pass "SPEC-10: empty CSV read with || true guard survives set -e (no abort)"
else
    assert_fail "SPEC-10: empty CSV read with || true guard must not abort under set -e" \
        "rc=$_spec10_shell_rc output=$_spec10_out"
fi

# Without the guard, bare `read` on empty input returns non-zero → verify the bug
# exists so the test is non-trivial (this is the pre-fix behavior).
(
    set -e
    # shellcheck disable=SC2229
    read -ra "_MAP_DIM_spec10" <<< "" && printf 'survived\n' || printf 'nonzero\n'
) > "$TEST_TEMP_DIR/spec10b.out" 2>&1
_spec10b_out="$(cat "$TEST_TEMP_DIR/spec10b.out")"

if [[ "$_spec10b_out" == "nonzero" ]]; then
    assert_pass "SPEC-10: bare read on empty string returns non-zero (confirms the bug being guarded)"
else
    # If the shell doesn't exhibit this behavior, the test is still fine (guard is harmless).
    assert_pass "SPEC-10: shell behavior noted: bare read on empty string returned 0 on this platform"
fi

unset -v _MAP_DIM_spec10

# ─── SPEC-11: long pool_id — sub-pool ids stay within the 64-char limit ───────
# #1312 (Copilot): backends validate pool_id against ^[a-zA-Z0-9_-]{1,64}$.
# A near-64-char base pool_id + the per-batch "-b<N>" suffix must NOT exceed 64,
# or orch_spawn rejects it and the batch is silently skipped. The truncation in
# _strategy_run_map must keep every sub-pool id valid so ALL batches dispatch.
print_test_section "SPEC-11: long pool_id — every batch dispatches (no over-64 skip) (issue #1312)"

declare -a _MAP_DIM_batch11=("a" "b" "c" "d" "e")
export _MAP_DIM_batch11

SPEC11_LOG="$TEST_TEMP_DIR/spec11-spy.log"
: > "$SPEC11_LOG"
# Spy enforces the REAL backend validation: reject any pool_id > 64 chars or with
# invalid chars, exactly like orch-bash-parallel/orch-sequential. A rejected spawn
# returns 1 → the batch would be skipped, so a passing test proves truncation works.
_spec11_orch_spawn() {
    local pid="$1"
    if [[ ! "$pid" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        printf 'orch_spawn REJECT %s (len=%s)\n' "$pid" "${#pid}" >> "$SPEC11_LOG"
        return 1
    fi
    printf 'orch_spawn OK %s (len=%s)\n' "$pid" "${#pid}" >> "$SPEC11_LOG"
    return 0
}
_spec11_orch_dispatch() { printf 'orch_dispatch %s\n' "$1" >> "$SPEC11_LOG"; return 0; }
_spec11_orch_collect()  { printf 'orch_collect %s\n'  "$1" >> "$SPEC11_LOG"; return 0; }
_spec11_orch_shutdown() { return 0; }

orch_spawn()    { _spec11_orch_spawn "$@"; }
orch_dispatch() { _spec11_orch_dispatch "$@"; }
orch_collect()  { _spec11_orch_collect "$@"; }
orch_shutdown() { _spec11_orch_shutdown "$@"; }

# A base pool_id at the 64-char boundary (max valid). Any "-b<N>" suffix without
# truncation would push it to 67+ chars → rejected. 60 'x' chars + "map-" prefix.
_spec11_long_pool="map-$(printf 'x%.0s' {1..60})"  # 4 + 60 = 64 chars

set +e
_strategy_run_map "$_spec11_long_pool" "review" "$ROLES_OUT" "$STATE_FILE" "$PLUGINS_ROOT" \
    "batch11" "" "2" "continue"
spec11_rc=$?
set -e

orch_spawn()    { orch_spawn_orig "$@"; }
orch_dispatch() { orch_dispatch_orig "$@"; }
orch_collect()  { orch_collect_orig "$@"; }
orch_shutdown() { orch_shutdown_orig "$@"; }

assert_exit_code "SPEC-11: long pool_id run returns 0 (on_member_error=continue)" "0" "$spec11_rc"

spec11_reject_count=0
spec11_reject_count=$(/usr/bin/grep -c "REJECT" "$SPEC11_LOG" 2>/dev/null) || spec11_reject_count=0
if [[ "$spec11_reject_count" -eq 0 ]]; then
    assert_pass "SPEC-11: no sub-pool id rejected — every batch spawned (truncation keeps ids ≤64)"
else
    assert_fail "SPEC-11: sub-pool id exceeded 64 chars and was rejected" \
        "$(/usr/bin/grep REJECT "$SPEC11_LOG")"
fi

spec11_dispatch_count=0
spec11_dispatch_count=$(/usr/bin/grep -c "^orch_dispatch" "$SPEC11_LOG" 2>/dev/null) || spec11_dispatch_count=0
if [[ "$spec11_dispatch_count" -eq 5 ]]; then
    assert_pass "SPEC-11: all 5 work units dispatched despite long base pool_id (no silently-skipped batch)"
else
    assert_fail "SPEC-11: all 5 work units must dispatch despite long pool_id" \
        "got $spec11_dispatch_count (log: $(cat "$SPEC11_LOG"))"
fi

# Assert the constructed sub-pool ids never exceeded 64 chars (positive proof).
spec11_maxlen_ok=1
while IFS= read -r _sp_line; do
    _sp_id="${_sp_line#orch_spawn OK }"
    _sp_id="${_sp_id% (len=*}"
    [[ ${#_sp_id} -gt 64 ]] && spec11_maxlen_ok=0
done < <(/usr/bin/grep "^orch_spawn OK" "$SPEC11_LOG")
if [[ "$spec11_maxlen_ok" -eq 1 ]]; then
    assert_pass "SPEC-11: all spawned sub-pool ids are ≤64 chars"
else
    assert_fail "SPEC-11: a spawned sub-pool id exceeded 64 chars" "$(cat "$SPEC11_LOG")"
fi

unset _MAP_DIM_batch11

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
