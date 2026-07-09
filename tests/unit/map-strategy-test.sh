#!/usr/bin/env bash
# Tests: core/pipeline/strategies/map.sh — unit tests (issue #1285, ADR-047)
# SPEC-1: platform dimension dispatches one-per-platform (byte-identical to fanout)
# SPEC-2: non-platform declared dimension dispatches one-per-element
# SPEC-3: empty dimension → no dispatch, no error (rc=3, caller maps to 0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/strategies/map — unit: data-driven dimension dispatch (issue #1285)"
setup_test_env "map-strategy-unit"

ORCH_SPY_LOG="$TEST_TEMP_DIR/orch-spy.log"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR" "$PLUGINS_ROOT"

source "$REPO_ROOT/core/pipeline/strategies/map.sh"
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

if [[ "$dispatch_count" -ge 2 ]]; then
    assert_pass "SPEC-1: orch_dispatch called for each platform (got $dispatch_count for 2 platforms)"
else
    assert_fail "SPEC-1: orch_dispatch called for each platform" "got $dispatch_count (expected >=2)"
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

if [[ "$lens_dispatch_count" -ge 3 ]]; then
    assert_pass "SPEC-2: orch_dispatch called once per lens element (got $lens_dispatch_count for 3 lenses)"
else
    assert_fail "SPEC-2: orch_dispatch called once per lens element" "got $lens_dispatch_count (expected >=3)"
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

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
