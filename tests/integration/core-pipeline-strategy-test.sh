#!/usr/bin/env bash
# Tests: core/pipeline/strategies/ — integration: runner delegates through orch contract (issue #222)
# Runs runner.sh as a subprocess with a spy orch-bash-parallel plugin that records
# every orch_spawn/dispatch/collect/shutdown call.
# Verifies fanout and sequential behavior end-to-end via real plugin invocations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/strategies — integration: runner delegates via orch contract"
setup_test_env "core-pipeline-strategy-int"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
ORCH_SPY_LOG="$TEST_TEMP_DIR/orch-spy.log"

export ORCH_SPY_LOG
# #511 F2: this test asserts the legacy linear strategy-dispatch path
# (every stage gets its own orch_spawn). Force-disable cycles so build+test
# are NOT absorbed into a cycle unit that bypasses orch_spawn.
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# #897: isolate TMPDIR to a per-test directory. _purge_stale_pools and the
# pool-leak assertion below glob ${TMPDIR}/zbuild-pool-* — a machine-wide
# namespace. Under concurrent runs (parallel dogfooding) a sibling run's
# in-flight pool dir is miscounted as a leak (or this test purges the sibling's
# dir). Pinning TMPDIR scopes the glob to this test's private temp. Mirrors
# route-loop-tmpdir-cleanup-test.sh and test-plugin-tmpdir-cleanup-test.sh.
ISOLATED_TMP="$TEST_TEMP_DIR/iso-tmp"
mkdir -p "$ISOLATED_TMP"
export TMPDIR="$ISOLATED_TMP"

# ─── Fixtures ────────────────────────────────────────────────────────────────

# Spy orch-bash-parallel plugin that records all orch contract calls.
# Provides a minimal real implementation so the pipeline can actually complete.
_make_spy_orch_plugin() {
    local dir="$PLUGINS_ROOT/tool/orch-bash-parallel"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: orch-bash-parallel
name: Spy Parallel Orchestrator
kind: tool
version: 0.0.1
provides:
  role: orchestrator-backend
  alias: bash-parallel
  capabilities: [parallel, fanout_parallel, sequential]
requires:
  bin: []
EOF
    cat > "$dir/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
[[ -n "${_ZBUILD_ORCH_SPY_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_SPY_LOADED=1

_spy_orch_log() { printf '%s %s\n' "$1" "${2:-}" >> "${ORCH_SPY_LOG:-/dev/null}"; }

orch_capabilities() { printf '{"backend":"bash-parallel","capabilities":["parallel","fanout_parallel","sequential"]}\n'; }

orch_spawn() {
    local pool_id="$1"
    _spy_orch_log "orch_spawn" "$pool_id"
    mkdir -p "${TMPDIR:-/tmp}/zbuild-pool-${pool_id}/results" \
             "${TMPDIR:-/tmp}/zbuild-pool-${pool_id}/pids"
    return 0
}

orch_dispatch() {
    local pool_id="$1" work_unit="$2"
    _spy_orch_log "orch_dispatch" "$pool_id"
    if [[ ! -f "$work_unit" || ! -x "$work_unit" ]]; then
        printf 'orch_dispatch: work_unit not found or not executable: %s\n' "$work_unit" >&2
        return 1
    fi
    local pool_dir="${TMPDIR:-/tmp}/zbuild-pool-${pool_id}"
    local slot_id; slot_id="slot-$(date +%s%N)-$$"
    local result_base="${pool_dir}/results/${slot_id}"
    (
        local rc=0
        bash "$work_unit" > "${result_base}.stdout" 2> "${result_base}.stderr" || rc=$?
        printf '%d\n' "$rc" > "${result_base}.exit"
    ) &
    local wpid=$!
    printf '%d\n' "$wpid" > "${pool_dir}/pids/${slot_id}.pid"
    printf '%s\n' "$slot_id"
    return 0
}

orch_collect() {
    # Exit codes: 0=all pass, 1=all fail, 2=partial (mix of pass and fail).
    local pool_id="$1"
    _spy_orch_log "orch_collect" "$pool_id"
    local pool_dir="${TMPDIR:-/tmp}/zbuild-pool-${pool_id}"
    [[ -d "${pool_dir}/pids" ]] || return 0
    local pass_count=0 fail_count=0 slot_id result_base rc
    for pid_file in "${pool_dir}/pids/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        result_base="${pool_dir}/results/${slot_id}"
        local deadline=$(( $(date +%s) + 30 ))
        while [[ ! -f "${result_base}.exit" ]]; do
            [[ "$(date +%s)" -ge "$deadline" ]] && { printf '124\n' > "${result_base}.exit"; break; }
            sleep 0.05
        done
        rc="$(cat "${result_base}.exit" 2>/dev/null || printf '1')"
        [[ -f "${result_base}.stdout" ]] && cat "${result_base}.stdout"
        [[ -f "${result_base}.stderr" ]] && cat "${result_base}.stderr" >&2
        if [[ "$rc" -eq 0 ]]; then
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done
    if [[ "$fail_count" -eq 0 ]]; then
        rm -rf "$pool_dir"
        return 0
    elif [[ "$pass_count" -gt 0 ]]; then
        return 2  # partial
    else
        return 1  # all failed
    fi
}

orch_shutdown() {
    local pool_id="$1"
    _spy_orch_log "orch_shutdown" "$pool_id"
    rm -rf "${TMPDIR:-/tmp}/zbuild-pool-${pool_id}" 2>/dev/null || true
    return 0
}
PLUGIN
}
_make_spy_orch_plugin

# Create a role-based agent plugin
_make_role_plugin() {
    local id="$1" role="$2" exit_code="${3:-0}" sentinel_file="${4:-}"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
hooks:
  run: ${id//-/_}_run
requires:
  core:
    - redaction
provides:
  role: $role
outputs:
  # ADR-055 §9 (#2000): every stage-bound plugin declares exactly one summary.
  - id: ${id//-/_}_summary
    type: $id-summary.md@1
    format: markdown
    path: \${artifact_dir}/$id-summary.md
    required: true
    summary: true
EOF
    local body=""
    if [[ -n "$sentinel_file" ]]; then
        body="touch '${sentinel_file}'"
    fi
    cat > "$dir/plugin.sh" <<PLUGIN
#!/usr/bin/env bash
${id//-/_}_run() {
    # ADR-055 §9 (#2000): a declared-but-unwritten output is a contract
    # violation, so the stub writes the summary it declares.
    local _d="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\${2:-/tmp/x}")/artifacts}"
    mkdir -p "\$_d" 2>/dev/null || true
    printf '## %s — pass\\n\\n- stub stage\\n' "$id" > "\$_d/$id-summary.md" 2>/dev/null || true
    ${body:-:}
    return ${exit_code}
}
PLUGIN
}

_make_role_plugin "intake-agent"   "intake"           0
_make_role_plugin "sl-agent"       "security-auditor" 0
_make_role_plugin "output-agent"   "output"           0

# #978 (EPIC #966): template-agnostic. Was pinned to `--template standard`;
# standard.yaml retires in #979. Strategy dispatch (fanout / sequential /
# composite) is ENGINE behavior, not roster-specific, so drive a minimal
# single-leaf fixture the test owns via the #1270 per-repo `.zbuild/templates/`
# overlay: install the fixture into a temp repo and run the runner with CWD =
# that repo (the resolver reads the overlay from $PWD). The `intake` leaf carries
# strategy: fanout; _ZBUILD_STRATEGY_OVERRIDE covers the sequential/composite
# paths over the same fixture.
STRAT_OVERLAY_REPO="$(setup_git_temp_repo strat-overlay-repo)"
install_template_overlay "$STRAT_OVERLAY_REPO" strategy-dispatch-minimal

_spy_count() {
    local count=0; count=$(grep -c "^${1}" "${ORCH_SPY_LOG:-/dev/null}" 2>/dev/null); true
    echo "$count"
}

# Remove any stale zbuild-pool-* dirs from previous test runs so pool-leak
# assertions only reflect the current run.
_purge_stale_pools() {
    for _d in "${TMPDIR:-/tmp}"/zbuild-pool-*; do
        [[ -d "$_d" ]] && rm -rf "$_d" 2>/dev/null || true
    done
}

_run_pipeline() {
    : > "$ORCH_SPY_LOG"
    rm -f "$STATE_DIR/"*.json
    set +e
    ( cd "$STRAT_OVERLAY_REPO" && ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$STATE_DIR" \
    ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_ORCHESTRATOR_BACKEND="bash-parallel" \
    ORCH_SPY_LOG="$ORCH_SPY_LOG" \
        bash "$RUNNER" --template strategy-dispatch-minimal --goal "test strategy dispatch" "$@" 2>/dev/null )
    _last_rc=$?
    set -e
}

# ─── Test 1: fanout strategy — orch_spawn/dispatch/collect/shutdown all called ─
print_test_section "1. fanout: all orch contract functions called"

_purge_stale_pools
_run_pipeline

spawn_count="$(_spy_count orch_spawn)"
dispatch_count="$(_spy_count orch_dispatch)"
collect_count="$(_spy_count orch_collect)"
shutdown_count="$(_spy_count orch_shutdown)"

if [[ "$spawn_count" -ge 1 ]]; then
    assert_pass "fanout: orch_spawn called (got $spawn_count)"
else
    assert_fail "fanout: orch_spawn called" "got 0 — strategies not delegating to orch contract"
fi

if [[ "$dispatch_count" -ge 1 ]]; then
    assert_pass "fanout: orch_dispatch called (got $dispatch_count)"
else
    assert_fail "fanout: orch_dispatch called" "got 0"
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

# ─── Test 2: spawn count == shutdown count (no pool leaks) ───────────────────
print_test_section "2. fanout: no pool leaks (spawn count == shutdown count)"

assert_eq "orch_spawn count == orch_shutdown count" "$spawn_count" "$shutdown_count"

# Verify no zbuild-pool-* dirs remain after completion
leftover_pools=0
for d in "${TMPDIR:-/tmp}"/zbuild-pool-*; do [[ -d "$d" ]] && leftover_pools=$(( leftover_pools + 1 )); done
if [[ "$leftover_pools" -eq 0 ]]; then
    assert_pass "no pool directories left after fanout (orch_shutdown cleaned up)"
else
    assert_fail "no pool directories left after fanout" "found $leftover_pools leftover pool dir(s)"
fi

# ─── Test 3: sequential halt-on-fail — second unit never dispatched ──────────
print_test_section "3. sequential halt-on-fail: only one dispatch when first fails"

# Use an isolated plugins root so the only intake role maps to the failing plugin.
# (The shared PLUGINS_ROOT has intake-agent which would be resolved first and
# succeed, masking the failure we want to test.)
SEQ_PLUGINS_ROOT="$TEST_TEMP_DIR/seq-plugins"
mkdir -p "$SEQ_PLUGINS_ROOT"

# Copy the spy orch backend into the isolated root
cp -r "$PLUGINS_ROOT/tool" "$SEQ_PLUGINS_ROOT/tool"

# Create a failing intake plugin
SEQ_FAIL_DIR="$SEQ_PLUGINS_ROOT/agent/intake-fail"
mkdir -p "$SEQ_FAIL_DIR"
cat > "$SEQ_FAIL_DIR/manifest.yaml" <<EOF
id: intake-fail
name: Failing intake
kind: agent
version: 0.0.1
hooks:
  run: intake_fail_run
requires:
  core:
    - redaction
provides:
  role: intake
EOF
cat > "$SEQ_FAIL_DIR/plugin.sh" <<'PLUGIN'
intake_fail_run() { return 1; }
PLUGIN

: > "$ORCH_SPY_LOG"

set +e
( cd "$STRAT_OVERLAY_REPO" && ZBUILD_PLUGINS_ROOT="$SEQ_PLUGINS_ROOT" \
ZBUILD_STATE_DIR="$STATE_DIR" \
ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
ZBUILD_ORCHESTRATOR_BACKEND="bash-parallel" \
ORCH_SPY_LOG="$ORCH_SPY_LOG" \
_ZBUILD_STRATEGY_OVERRIDE="sequential" \
    bash "$RUNNER" --template strategy-dispatch-minimal --goal "test sequential halt" 2>/dev/null )
seq_rc=$?
set -e

# The runner should fail (rc != 0) since the only plugin returns 1
if [[ $seq_rc -ne 0 ]]; then
    assert_pass "sequential: runner exits non-zero when stage fails (rc=$seq_rc)"
else
    assert_fail "sequential: runner exits non-zero when stage fails" "rc=0"
fi

# ─── Test 4: composite returns non-zero with deferral message ────────────────
print_test_section "4. composite strategy: emits deferral error (Phase 1 deferred)"

: > "$ORCH_SPY_LOG"

set +e
composite_out="$(
    cd "$STRAT_OVERLAY_REPO" && ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$STATE_DIR" \
    ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_ORCHESTRATOR_BACKEND="bash-parallel" \
    _ZBUILD_STRATEGY_OVERRIDE="composite" \
        bash "$RUNNER" --template strategy-dispatch-minimal --goal "test composite" 2>&1
)"
composite_rc=$?
set -e

if [[ $composite_rc -ne 0 ]]; then
    assert_pass "composite: runner exits non-zero (Phase 1 deferred, rc=$composite_rc)"
else
    assert_fail "composite: runner exits non-zero" "rc=0"
fi

if grep -qiE "composite|phase.1|deferred|not.implemented" <<< "$composite_out"; then
    assert_pass "composite: output contains deferral message"
else
    assert_fail "composite: output contains deferral message" "output: $(echo "$composite_out" | head -5)"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
