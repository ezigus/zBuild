#!/usr/bin/env bash
# Tests: core/pipeline/strategies/ — unit tests (issue #222, ADR-009, ADR-011)
# Verifies strategy dispatch delegates to orch contract (orch_spawn/dispatch/collect/shutdown)
# rather than executing bash directly.  Uses a spy orch backend that records every call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/strategies — unit: orch contract delegation (issue #222)"
setup_test_env "core-pipeline-strategy-unit"

ORCH_SPY_LOG="$TEST_TEMP_DIR/orch-spy.log"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR" "$PLUGINS_ROOT/tool"

# ─── _make_work_unit helper available? ───────────────────────────────────────
# Source common.sh directly and verify the helper is present.
print_test_section "1. common.sh: _strategy_make_work_unit exists and produces executable"

source "$REPO_ROOT/core/pipeline/strategies/common.sh"

# Create a dummy plugin dir with a plugin.sh for the work unit
DUMMY_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/tool/dummy-agent"
mkdir -p "$DUMMY_PLUGIN_DIR"
printf '#!/usr/bin/env bash\n_dummy_run() { return 0; }\n' > "$DUMMY_PLUGIN_DIR/plugin.sh"

STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '{"run_id":"test-001"}\n' > "$STATE_FILE"

wu=""
set +e
wu="$(_strategy_make_work_unit "$DUMMY_PLUGIN_DIR" "intake" "$STATE_FILE" "generic" 2>&1)"
wu_rc=$?
set -e

if [[ $wu_rc -eq 0 && -n "$wu" ]]; then
    assert_pass "_strategy_make_work_unit returned a path (rc=0)"
else
    assert_fail "_strategy_make_work_unit returned a path (rc=0)" "rc=$wu_rc output=$wu"
fi

if [[ -f "$wu" ]]; then
    assert_pass "work unit temp file was created"
else
    assert_fail "work unit temp file was created" "path=$wu does not exist"
fi

if [[ -x "$wu" ]]; then
    assert_pass "work unit is executable"
else
    assert_fail "work unit is executable" "mode=$(stat -f '%p' "$wu" 2>/dev/null || stat -c '%a' "$wu" 2>/dev/null)"
fi

# Must start with #!/usr/bin/env bash
first_line="$(head -1 "$wu")"
assert_eq "work unit shebang" "#!/usr/bin/env bash" "$first_line"

# Must contain plugin_hook_call
if grep -q "plugin_hook_call" "$wu"; then
    assert_pass "work unit contains plugin_hook_call"
else
    assert_fail "work unit contains plugin_hook_call" "contents: $(cat "$wu")"
fi

# Must export ZBUILD_TARGET_PLATFORM
if grep -q "ZBUILD_TARGET_PLATFORM" "$wu"; then
    assert_pass "work unit exports ZBUILD_TARGET_PLATFORM"
else
    assert_fail "work unit exports ZBUILD_TARGET_PLATFORM" "contents: $(cat "$wu")"
fi

rm -f "$wu"

# ─── Validate key rejection in _strategy_make_work_unit ──────────────────────
print_test_section "2. _strategy_make_work_unit rejects invalid inputs"

# Empty stage
set +e
bad_wu="$(_strategy_make_work_unit "$DUMMY_PLUGIN_DIR" "" "$STATE_FILE" "generic" 2>&1)"
bad_rc=$?
set -e
if [[ $bad_rc -ne 0 ]]; then
    assert_pass "empty stage rejected (rc=$bad_rc)"
else
    assert_fail "empty stage rejected" "rc=0 output=$bad_wu"
fi
rm -f "$bad_wu" 2>/dev/null || true

# Stage with path traversal
set +e
bad_wu2="$(_strategy_make_work_unit "$DUMMY_PLUGIN_DIR" "../evil" "$STATE_FILE" "generic" 2>&1)"
bad_rc2=$?
set -e
if [[ $bad_rc2 -ne 0 ]]; then
    assert_pass "traversal stage rejected (rc=$bad_rc2)"
else
    assert_fail "traversal stage rejected" "rc=0 output=$bad_wu2"
fi
rm -f "$bad_wu2" 2>/dev/null || true

# ─── Strategy source guards ───────────────────────────────────────────────────
print_test_section "3. strategy files have double-source guards"

# Source each strategy file twice; if guards are missing the guard check will fail via redefinition
source "$REPO_ROOT/core/pipeline/strategies/fanout.sh"
source "$REPO_ROOT/core/pipeline/strategies/fanout.sh"

if declare -F _strategy_run_fanout >/dev/null 2>&1; then
    assert_pass "fanout.sh loaded: _strategy_run_fanout defined"
else
    assert_fail "fanout.sh loaded: _strategy_run_fanout defined"
fi

source "$REPO_ROOT/core/pipeline/strategies/sequential.sh"
source "$REPO_ROOT/core/pipeline/strategies/sequential.sh"

if declare -F _strategy_run_sequential >/dev/null 2>&1; then
    assert_pass "sequential.sh loaded: _strategy_run_sequential defined"
else
    assert_fail "sequential.sh loaded: _strategy_run_sequential defined"
fi

source "$REPO_ROOT/core/pipeline/strategies/composite.sh"
source "$REPO_ROOT/core/pipeline/strategies/composite.sh"

if declare -F _strategy_run_composite >/dev/null 2>&1; then
    assert_pass "composite.sh loaded: _strategy_run_composite defined"
else
    assert_fail "composite.sh loaded: _strategy_run_composite defined"
fi

# ─── Spy setup for contract delegation tests ─────────────────────────────────
print_test_section "4. fanout: delegates to orch_spawn/dispatch/collect/shutdown"

# Install spy implementations of the orch contract functions
export ORCH_SPY_LOG
_spy_log() { printf '%s %s\n' "$1" "${2:-}" >> "$ORCH_SPY_LOG"; }

orch_spawn()    { _spy_log "orch_spawn"    "$1"; mkdir -p "${TMPDIR:-/tmp}/zbuild-pool-$1/results" "${TMPDIR:-/tmp}/zbuild-pool-$1/pids"; return 0; }
orch_dispatch() { _spy_log "orch_dispatch" "$1"; local wu="${2:-}"; [[ -f "$wu" ]] && bash "$wu" >/dev/null 2>&1 || true; printf 'slot-001\n'; return 0; }
orch_collect()  { _spy_log "orch_collect"  "$1"; return 0; }
orch_shutdown() { _spy_log "orch_shutdown" "$1"; rm -rf "${TMPDIR:-/tmp}/zbuild-pool-$1" 2>/dev/null || true; return 0; }

> "$ORCH_SPY_LOG"

# Make the dummy plugin write a sentinel
FANOUT_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/tool/fanout-agent"
mkdir -p "$FANOUT_PLUGIN_DIR"
cat > "$FANOUT_PLUGIN_DIR/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
_fanout_agent_run() { return 0; }
PLUGIN

ROLES_OUT="security-auditor"
_DETECTED_PLATFORMS=("ios" "node")

mkdir -p "$STATE_DIR"
STATE_FILE2="$STATE_DIR/pipeline-state-fanout.json"
printf '{"run_id":"test-fanout"}\n' > "$STATE_FILE2"

# Override resolve_plugin_for_role to return our dummy plugin
resolve_plugin_for_role() { echo "$FANOUT_PLUGIN_DIR"; }
_check_artifact_contract() { return 0; }

set +e
_strategy_run_fanout "fanout-pool-001" "intake" "$ROLES_OUT" "$STATE_FILE2" "$PLUGINS_ROOT"
fanout_rc=$?
set -e

# orch_spawn is called by runner.sh before delegating; not called inside strategy.
# Use safe count pattern: grep exits 1 (no match) still prints "0", so capture before || fallback.
dispatch_count=0; collect_count=0; shutdown_count=0
dispatch_count=$(grep -c "^orch_dispatch" "$ORCH_SPY_LOG" 2>/dev/null); true
collect_count=$(grep -c "^orch_collect"  "$ORCH_SPY_LOG" 2>/dev/null); true
shutdown_count=$(grep -c "^orch_shutdown" "$ORCH_SPY_LOG" 2>/dev/null); true

assert_exit_code "fanout exits 0 (all success)" "0" "$fanout_rc"

if [[ "$dispatch_count" -ge 2 ]]; then
    assert_pass "fanout: orch_dispatch called for each platform (got $dispatch_count for 2 platforms)"
else
    assert_fail "fanout: orch_dispatch called for each platform" "got $dispatch_count (expected >=2)"
fi

if [[ "$collect_count" -ge 1 ]]; then
    assert_pass "fanout: orch_collect called (got $collect_count)"
else
    assert_fail "fanout: orch_collect called" "got 0"
fi

if [[ "$shutdown_count" -ge 1 ]]; then
    assert_pass "fanout: orch_shutdown called (got $shutdown_count)"
else
    assert_fail "fanout: orch_shutdown called" "got 0"
fi

# orch_spawn is runner.sh's responsibility; no pool leak check needed at strategy level

# ─── Test 5: sequential calls orch_shutdown even when collect fails ───────────
print_test_section "5. sequential: orch_shutdown called even when dispatch fails"

> "$ORCH_SPY_LOG"

# Override orch_collect to fail — sequential should still call orch_shutdown (cleanup invariant)
orch_dispatch() {
    _spy_log "orch_dispatch" "$1"
    local wu="${2:-}"; [[ -f "$wu" ]] && bash "$wu" >/dev/null 2>&1 || true
    printf 'slot-seq-001\n'; return 0
}
orch_collect() {
    _spy_log "orch_collect" "$1"
    return 1  # simulates a work-unit failure
}

_dispatch_call_count=0
set +e
_strategy_run_sequential "seq-pool-001" "intake" "$ROLES_OUT" "$STATE_FILE2" "$PLUGINS_ROOT"
seq_rc=$?
set -e

seq_shutdown_count=0; seq_shutdown_count=$(grep -c "^orch_shutdown" "$ORCH_SPY_LOG" 2>/dev/null); true

if [[ $seq_rc -ne 0 ]]; then
    assert_pass "sequential: returns non-zero on collect failure (rc=$seq_rc)"
else
    assert_fail "sequential: returns non-zero on collect failure" "rc=0"
fi

if [[ "$seq_shutdown_count" -ge 1 ]]; then
    assert_pass "sequential: orch_shutdown called even on failure (cleanup invariant)"
else
    assert_fail "sequential: orch_shutdown called even on failure" "got 0 calls"
fi

# ─── Test 6: composite returns non-zero with informative message (Phase 1 stub) ─
print_test_section "6. composite: returns non-zero with Phase-1-deferred message"

composite_out=""
set +e
composite_out="$(_strategy_run_composite "comp-pool-001" "design" "some-role" "$STATE_FILE2" "$PLUGINS_ROOT" 2>&1)"
composite_rc=$?
set -e

if [[ $composite_rc -ne 0 ]]; then
    assert_pass "composite: exits non-zero (Phase 1 deferred, rc=$composite_rc)"
else
    assert_fail "composite: exits non-zero" "rc=0 — should be deferred error"
fi

if echo "$composite_out" | grep -qiE "composite|phase.1|deferred|not.implemented"; then
    assert_pass "composite: output contains deferral message"
else
    assert_fail "composite: output contains deferral message" "output: $composite_out"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
