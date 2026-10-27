#!/usr/bin/env bash
# tests/integration/orch-timeout-applies-test.sh
#
# SPEC-1 (#1801): A hung work unit dispatched through the fanout, map, or
# sequential strategy stops at its stage template `timeout_s:` limit; the
# 300 s flat deadline no longer applies.
#
# Old code: every strategy calls
#   orch_collect "$pool_id" --timeout "${ZBUILD_ORCH_TIMEOUT:-300}"
# New code: every strategy calls
#   orch_collect "$pool_id" --timeout "$(template_stage_time_limit "$stage")"
#
# This test fails on old code (spy captures 300), passes on new code
# (spy captures the template's timeout_s: value).
#
# [#1801/SPEC-1]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# template.sh also sources scripts/lib/stage-time-limit.sh
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "orch strategies pass template timeout_s: (not 300s) to orch_collect (#1801 SPEC-1)"
setup_test_env "orch-timeout-applies"

# ── Template with timeout_s: 7 for stage "testjob" ──────────────────────────
# The spy test asserts orch_collect receives --timeout 7, NOT --timeout 300.
TPL="$TEST_TEMP_DIR/tpl-spec1.yaml"
cat > "$TPL" <<'YAML'
id: tpl-spec1
name: spec1 test
defaults:
  strategy: fanout
flow:
  - testjob
testjob:
  roles: [testworker]
  timeout_s: 7
YAML
load_template "$TPL" >/dev/null 2>&1

# Source the strategies (after template.sh so _TPL_SOURCE_FILE is set)
# shellcheck source=../../core/pipeline/strategies/fanout.sh
source "$REPO_ROOT/core/pipeline/strategies/fanout.sh"
# shellcheck source=../../core/pipeline/strategies/sequential.sh
source "$REPO_ROOT/core/pipeline/strategies/sequential.sh"
# shellcheck source=../../core/pipeline/strategies/map.sh
source "$REPO_ROOT/core/pipeline/strategies/map.sh"

# ── Minimal plugin for resolve_plugin_for_role ───────────────────────────────
_SPEC1_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/agent/testworker"
mkdir -p "$_SPEC1_PLUGIN_DIR"
cat > "$_SPEC1_PLUGIN_DIR/manifest.yaml" <<'MF'
id: testworker
name: testworker
kind: agent
version: 0.0.1
hooks:
  run: testworker_run
provides:
  role: testworker
MF
cat > "$_SPEC1_PLUGIN_DIR/plugin.sh" <<'PL'
testworker_run() { return 0; }
PL

# Mock orch functions, platform detection, and plugin resolution so the
# strategy machinery runs without a real backend or runner environment.
_DETECTED_PLATFORMS=("generic")
resolve_plugin_for_role() { printf '%s\n' "$_SPEC1_PLUGIN_DIR"; return 0; }

_SPEC1_OC_TIMEOUT=""
_SPEC1_OC_CALLS=0
orch_collect() {
    _SPEC1_OC_CALLS=$(( _SPEC1_OC_CALLS + 1 ))
    _SPEC1_OC_TIMEOUT=""
    local _s1_pool="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) _SPEC1_OC_TIMEOUT="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done
    _ORCH_COLLECT_OUTCOME=""
    return 0
}
orch_spawn()    { return 0; }
orch_dispatch() { printf 'slot-%s\n' "$$"; return 0; }
orch_shutdown() { return 0; }

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR"
printf '{"schema_version":1}' > "$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_RUN_ID="spec1-test"
export ZBUILD_ORCH_SCRATCH="$TEST_TEMP_DIR/orch-scratch"
mkdir -p "$ZBUILD_ORCH_SCRATCH"
export ZBUILD_CURRENT_STAGE="testjob"

_spec1_expected_timeout="$(template_stage_time_limit testjob)"

# ── SPEC-1a: fanout passes template timeout_s: (not 300) to orch_collect ─────
print_test_section "[#1801/SPEC-1] fanout strategy uses template_stage_time_limit for orch_collect"
unset ZBUILD_ORCH_TIMEOUT 2>/dev/null || true
_SPEC1_OC_TIMEOUT=""
_s1a_rc=0
_strategy_run_fanout "pool-fanout-spec1" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" 2>/dev/null || _s1a_rc=$?

if [[ "$_SPEC1_OC_TIMEOUT" == "$_spec1_expected_timeout" ]]; then
    assert_pass "[#1801/SPEC-1] fanout: orch_collect received --timeout ${_spec1_expected_timeout} (template timeout_s:, not 300)"
else
    assert_fail "[#1801/SPEC-1] fanout: orch_collect must receive template timeout_s: (${_spec1_expected_timeout})" \
        "spy captured --timeout '${_SPEC1_OC_TIMEOUT:-<none>}'; old code passes ZBUILD_ORCH_TIMEOUT:-300 = 300"
fi

# With ZBUILD_ORCH_TIMEOUT=300 set explicitly, new code must still ignore it
export ZBUILD_ORCH_TIMEOUT=300
_SPEC1_OC_TIMEOUT=""
_s1a2_rc=0
_strategy_run_fanout "pool-fanout-spec1b" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" 2>/dev/null || _s1a2_rc=$?
if [[ "$_SPEC1_OC_TIMEOUT" == "$_spec1_expected_timeout" ]]; then
    assert_pass "[#1801/SPEC-1] fanout: ZBUILD_ORCH_TIMEOUT=300 does not override template timeout_s: (${_spec1_expected_timeout})"
else
    assert_fail "[#1801/SPEC-1] fanout: template timeout_s: (${_spec1_expected_timeout}) must win over ZBUILD_ORCH_TIMEOUT=300" \
        "spy got --timeout '${_SPEC1_OC_TIMEOUT:-<none>}'; old code passes ZBUILD_ORCH_TIMEOUT:-300 = 300"
fi
unset ZBUILD_ORCH_TIMEOUT 2>/dev/null || true

# ── SPEC-1b: sequential passes template timeout_s: (not 300) to orch_collect ─
print_test_section "[#1801/SPEC-1] sequential strategy uses template_stage_time_limit for orch_collect"
_SPEC1_OC_TIMEOUT=""
_s1b_rc=0
_strategy_run_sequential "pool-seq-spec1" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" 2>/dev/null || _s1b_rc=$?

if [[ "$_SPEC1_OC_TIMEOUT" == "$_spec1_expected_timeout" ]]; then
    assert_pass "[#1801/SPEC-1] sequential: orch_collect received --timeout ${_spec1_expected_timeout} (template timeout_s:, not 300)"
else
    assert_fail "[#1801/SPEC-1] sequential: orch_collect must receive template timeout_s: (${_spec1_expected_timeout})" \
        "spy captured --timeout '${_SPEC1_OC_TIMEOUT:-<none>}'; old code passes ZBUILD_ORCH_TIMEOUT:-300 = 300"
fi

# With ZBUILD_ORCH_TIMEOUT=300 set, sequential must still use template value
export ZBUILD_ORCH_TIMEOUT=300
_SPEC1_OC_TIMEOUT=""
_s1b2_rc=0
_strategy_run_sequential "pool-seq-spec1b" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" 2>/dev/null || _s1b2_rc=$?
if [[ "$_SPEC1_OC_TIMEOUT" == "$_spec1_expected_timeout" ]]; then
    assert_pass "[#1801/SPEC-1] sequential: ZBUILD_ORCH_TIMEOUT=300 does not override template timeout_s: (${_spec1_expected_timeout})"
else
    assert_fail "[#1801/SPEC-1] sequential: template timeout_s: (${_spec1_expected_timeout}) must win over ZBUILD_ORCH_TIMEOUT=300" \
        "spy got --timeout '${_SPEC1_OC_TIMEOUT:-<none>}'"
fi
unset ZBUILD_ORCH_TIMEOUT 2>/dev/null || true

# ── SPEC-1c: map strategy static guard — no longer references ZBUILD_ORCH_TIMEOUT ─
# map strategy is too complex to spy on (FIFO pool, sub-pools, batch dispatch),
# but the static guard catches the pattern change at source level.
print_test_section "[#1801/SPEC-1] map strategy no longer uses ZBUILD_ORCH_TIMEOUT (static guard)"
_MAP_SH="$REPO_ROOT/core/pipeline/strategies/map.sh"
assert_file_exists "SPEC-0: map.sh exists" "$_MAP_SH"
if grep -q 'template_stage_time_limit' "$_MAP_SH"; then
    assert_pass "[#1801/SPEC-1] map strategy calls template_stage_time_limit for orch_collect timeout"
else
    assert_fail "[#1801/SPEC-1] map strategy must call template_stage_time_limit for orch_collect timeout" \
        "not found in $_MAP_SH; old code passes ZBUILD_ORCH_TIMEOUT:-300"
fi
if ! grep -q 'ZBUILD_ORCH_TIMEOUT' "$_MAP_SH"; then
    assert_pass "[#1801/SPEC-1] map strategy does not reference ZBUILD_ORCH_TIMEOUT (flat 300 s deadline removed)"
else
    assert_fail "[#1801/SPEC-1] map strategy must not reference ZBUILD_ORCH_TIMEOUT (flat 300 s deadline)" \
        "ZBUILD_ORCH_TIMEOUT still present in $_MAP_SH"
fi

# ── SPEC-1d: fanout and sequential also have no ZBUILD_ORCH_TIMEOUT reference ─
print_test_section "[#1801/SPEC-1] fanout and sequential source files have no ZBUILD_ORCH_TIMEOUT"
for _s1_strat in fanout sequential; do
    _s1_file="$REPO_ROOT/core/pipeline/strategies/${_s1_strat}.sh"
    if ! grep -q 'ZBUILD_ORCH_TIMEOUT' "$_s1_file"; then
        assert_pass "[#1801/SPEC-1] ${_s1_strat}.sh: ZBUILD_ORCH_TIMEOUT removed (flat 300 s deadline gone)"
    else
        assert_fail "[#1801/SPEC-1] ${_s1_strat}.sh: ZBUILD_ORCH_TIMEOUT must not remain" \
            "still present in $_s1_file; the 300 s flat deadline applies on old code"
    fi
done

# ── SPEC-1 (map runtime spy): map passes template timeout_s: to orch_collect ──
# map.sh uses ZBUILD_ORCH_TIMEOUT:-300 on old code; must use template_stage_time_limit
# on new code. The spy (defined above) is still the capturing version at this point.
# Fails on old code (spy captures 300); passes on new code (spy captures _spec1_expected_timeout).
print_test_section "[#1801/SPEC-1] map strategy uses template_stage_time_limit for orch_collect (runtime spy)"
unset ZBUILD_ORCH_TIMEOUT 2>/dev/null || true
_SPEC1_OC_TIMEOUT=""
_s1m_rc=0
_strategy_run_map "pool-map-spec1" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" 2>/dev/null || _s1m_rc=$?

if [[ "$_SPEC1_OC_TIMEOUT" == "$_spec1_expected_timeout" ]]; then
    assert_pass "[#1801/SPEC-1] map: orch_collect received --timeout ${_spec1_expected_timeout} (template timeout_s:, not 300)"
else
    assert_fail "[#1801/SPEC-1] map: orch_collect must receive template timeout_s: (${_spec1_expected_timeout})" \
        "spy captured --timeout '${_SPEC1_OC_TIMEOUT:-<none>}'; old code passes ZBUILD_ORCH_TIMEOUT:-300 = 300"
fi

# With ZBUILD_ORCH_TIMEOUT=300 explicitly set, map must still ignore it.
export ZBUILD_ORCH_TIMEOUT=300
_SPEC1_OC_TIMEOUT=""
_s1m2_rc=0
_strategy_run_map "pool-map-spec1b" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" 2>/dev/null || _s1m2_rc=$?
if [[ "$_SPEC1_OC_TIMEOUT" == "$_spec1_expected_timeout" ]]; then
    assert_pass "[#1801/SPEC-1] map: ZBUILD_ORCH_TIMEOUT=300 does not override template timeout_s: (${_spec1_expected_timeout})"
else
    assert_fail "[#1801/SPEC-1] map: template timeout_s: (${_spec1_expected_timeout}) must win over ZBUILD_ORCH_TIMEOUT=300" \
        "spy got --timeout '${_SPEC1_OC_TIMEOUT:-<none>}'; old code passes ZBUILD_ORCH_TIMEOUT:-300 = 300"
fi
unset ZBUILD_ORCH_TIMEOUT 2>/dev/null || true

# ── SPEC-1e: _orch_local_collect_results sets _ORCH_COLLECT_OUTCOME=timed_out ─
# This is a runtime test: start a real hung process, run collect with a 2 s
# timeout, and assert the outcome variable is "timed_out" not "failed".
# Fails on old code (sets "failed" because rc=124 is just a non-zero exit).
print_test_section "[#1801/SPEC-1] _orch_local_collect_results sets timed_out outcome on timeout"
# shellcheck source=../../core/orch/local_engine.sh
source "$REPO_ROOT/core/orch/local_engine.sh"
# proc-group.sh must be available so the new kill path compiles cleanly.
# shellcheck source=../../scripts/lib/proc-group.sh
source "$REPO_ROOT/scripts/lib/proc-group.sh"

_s1e_pool="$TEST_TEMP_DIR/spec1e-pool"
mkdir -p "$_s1e_pool/pids" "$_s1e_pool/results"

# Start a process that will run for 60 s — it will never write a .exit file.
sleep 60 &
_s1e_pid=$!
printf '%s\n' "$_s1e_pid" > "$_s1e_pool/pids/spec1e.pid"

_s1e_rc=0
_orch_local_collect_results "$_s1e_pool" "pids" 2 || _s1e_rc=$?
_s1e_outcome="$_ORCH_COLLECT_OUTCOME"

# Ensure the sleeping process is cleaned up regardless of outcome.
kill "$_s1e_pid" 2>/dev/null || true
wait "$_s1e_pid" 2>/dev/null || true

if [[ "$_s1e_outcome" == "timed_out" ]]; then
    assert_pass "[#1801/SPEC-1] _orch_local_collect_results sets _ORCH_COLLECT_OUTCOME=timed_out on timeout"
else
    assert_fail "[#1801/SPEC-1] _orch_local_collect_results must set _ORCH_COLLECT_OUTCOME=timed_out on timeout" \
        "got '${_s1e_outcome:-<empty>}'; old code sets 'failed' because rc=124 counts as a non-zero exit"
fi

# ── SPEC-1f: strategy propagates timed_out outcome; output names stage+limit ─
# Mock orch_collect to simulate a timeout (return 1 with _ORCH_COLLECT_OUTCOME=
# "timed_out"). Assert the strategy (a) propagates _ZB_STRATEGY_OUTCOME="timed_out"
# and (b) emits the stage name and the limit to stderr.
# Fails on old code: old code has no timed_out branch → _ZB_STRATEGY_OUTCOME="failed"
# and no stage/limit in the timeout message.
print_test_section "[#1801/SPEC-1] strategy propagates timed_out; output names stage and limit exceeded"
orch_collect() {
    _ORCH_COLLECT_OUTCOME="timed_out"
    return 1
}

_ZB_STRATEGY_OUTCOME=""
_s1f_timeout="$(template_stage_time_limit testjob)"
# Run directly in the parent shell (not a subshell) so _ZB_STRATEGY_OUTCOME
# set inside _strategy_run_fanout is visible after the call. Capture all output
# (stdout + stderr) to a temp file and read it back into _s1f_stderr.
_s1f_stderr_file="$TEST_TEMP_DIR/spec1f-stderr.txt"
_s1f_rc=0
_strategy_run_fanout "pool-spec1f" "testjob" "testworker" \
    "$ZBUILD_STATE_DIR/pipeline-state.json" \
    "$TEST_TEMP_DIR/plugins" >"$_s1f_stderr_file" 2>&1 || _s1f_rc=$?
_s1f_stderr="$(cat "$_s1f_stderr_file" 2>/dev/null || true)"

if [[ "${_ZB_STRATEGY_OUTCOME:-}" == "timed_out" ]]; then
    assert_pass "[#1801/SPEC-1] fanout strategy propagates timed_out from _ORCH_COLLECT_OUTCOME"
else
    assert_fail "[#1801/SPEC-1] fanout strategy must propagate timed_out from _ORCH_COLLECT_OUTCOME" \
        "got '${_ZB_STRATEGY_OUTCOME:-<empty>}'; old code passes collect_rc=1 → _ZB_STRATEGY_OUTCOME=failed"
fi

# The result must name the stage ("testjob").
if grep -q 'testjob' <<< "$_s1f_stderr"; then
    assert_pass "[#1801/SPEC-1] fanout timed_out output names the stage ('testjob')"
else
    assert_fail "[#1801/SPEC-1] fanout timed_out output must name the stage ('testjob')" \
        "stage not found in output: '${_s1f_stderr:0:300}'"
fi

# The result must name the limit (the template's timeout_s: value).
if grep -q "${_s1f_timeout}" <<< "$_s1f_stderr"; then
    assert_pass "[#1801/SPEC-1] fanout timed_out output names the timeout limit (${_s1f_timeout}s)"
else
    assert_fail "[#1801/SPEC-1] fanout timed_out output must name the timeout limit (${_s1f_timeout}s)" \
        "limit not found in output: '${_s1f_stderr:0:300}'"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
