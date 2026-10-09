#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline memory-guard test                                    ║
# ║                                                                           ║
# ║  Validates the per-host admission gate that prevents concurrent pipelines ║
# ║  from OOM-killing the machine.                                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    setup_test_env "sw-pipeline-memory-guard"
    export SHIPWRIGHT_ACTIVE_PIPELINES_DIR="$TEST_TEMP_DIR/home/.shipwright/active-pipelines"
    mkdir -p "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"
    # Source the helpers we want to exercise. Loading the full pipeline script
    # would trigger preflight + lots of init; sub-source just the helpers.
    # We achieve that by sourcing into a function-scope shell with side effects
    # disabled.
    export SHIPWRIGHT_MAX_ACTIVE_PIPELINES=1
    export SHIPWRIGHT_MIN_FREE_GB=4
}

_test_cleanup_hook() { cleanup_test_env; }

# Helper: source the pipeline script in a controlled way that defines the
# helpers without invoking the CLI dispatcher. We rely on the script being
# idempotently sourceable (it defines functions and variables at the top
# level, and only dispatches when invoked as a script via $1 case).
load_helpers() {
    # Mark as test mode and stub out heavy init calls.
    set +u
    # shellcheck source=sw-pipeline.sh
    # Source only the function definitions we need by extracting them into a
    # standalone snippet — full source pulls in too many side-effecting
    # `source` calls (lib/bootstrap.sh etc.) which don't matter for these
    # unit tests.
    eval "$(awk '
        /^get_free_memory_gb\(\) \{/      {p=1}
        /^pid_exists\(\) \{/              {p=1}
        /^reap_stale_pipeline_locks\(\) \{/ {p=1}
        /^count_active_pipeline_locks\(\) \{/ {p=1}
        /^write_active_pipeline_lock\(\) \{/ {p=1}
        /^release_active_pipeline_lock\(\) \{/ {p=1}
        /^_describe_blocking_lock\(\) \{/ {p=1}
        /^check_admission_gate\(\) \{/    {p=1}
        p {print}
        p && /^\}$/ {p=0}
    ' "$SCRIPT_DIR/sw-pipeline.sh")"
    set -u
    # Stubs for color/output helpers + emit_event used by the helpers.
    # Variables below are consumed indirectly by write_active_pipeline_lock,
    # so shellcheck flags them as unused — silence the false positives.
    # shellcheck disable=SC2034
    {
        DIM=""
        RESET=""
        PIPELINE_NAME="standard"
        ISSUE_NUMBER=""
        GOAL=""
        ORIGINAL_REPO_DIR="$TEST_TEMP_DIR/project"
    }
    _PIPELINE_PID="$$"
    _ACTIVE_PIPELINE_LOCK_FILE=""
    error()      { echo "ERROR: $*" >&2; }
    info()       { echo "INFO: $*"; }
    warn()       { echo "WARN: $*" >&2; }
    success()    { echo "OK: $*"; }
    emit_event() { :; }
    now_iso()    { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "Shipwright Pipeline Memory Guard"

setup_env
load_helpers

# ─── Test 1: write_active_pipeline_lock creates a valid JSON file ────────────
echo -e "${DIM}  lock file write${RESET}"
if write_active_pipeline_lock; then
    assert_pass "write_active_pipeline_lock returns 0"
else
    assert_fail "write_active_pipeline_lock returns 0"
fi
lock_file="$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/$_PIPELINE_PID.json"
assert_file_exists "lock file created at expected path" "$lock_file"
if [[ -f "$lock_file" ]]; then
    pid_in_file=$(jq -r '.pid' "$lock_file" 2>/dev/null || echo "")
    assert_eq "lock file contains correct pid" "$_PIPELINE_PID" "$pid_in_file"
    template_in_file=$(jq -r '.pipeline_template' "$lock_file" 2>/dev/null || echo "")
    assert_eq "lock file contains pipeline_template" "standard" "$template_in_file"
fi

# ─── Test 2: release_active_pipeline_lock removes the file (idempotent) ──────
echo ""
echo -e "${DIM}  lock release${RESET}"
release_active_pipeline_lock
assert_file_not_exists "lock file removed after release" "$lock_file"
# Idempotent — second call must not error
if release_active_pipeline_lock; then
    assert_pass "release is idempotent"
else
    assert_fail "release is idempotent"
fi

# ─── Test 3: admission gate refuses when an active lock already exists ───────
echo ""
echo -e "${DIM}  admission refusal: concurrency cap${RESET}"
# Plant a lock from "another" running pipeline (use our own pid, which is alive)
other_pid="$$"
cat > "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/$other_pid.json" <<EOF
{"pid":$other_pid,"started_at":"2026-04-26T00:00:00Z","issue_or_goal":"42","repo":"/tmp/other","pipeline_template":"standard"}
EOF
# Force a different reported PID for the candidate process
saved_pid="$_PIPELINE_PID"
_PIPELINE_PID=$((other_pid + 1))
# Stub out get_free_memory_gb so memory doesn't interfere with concurrency test
get_free_memory_gb() { echo 999; }
output=$(check_admission_gate 2>&1) && rc=0 || rc=$?
_PIPELINE_PID="$saved_pid"
assert_eq "admission_gate refuses when at capacity" "1" "$rc"
assert_contains "diagnostic names blocking pid" "$output" "pid=$other_pid"
assert_contains "diagnostic names policy max" "$output" "max=1"
rm -f "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/$other_pid.json"

# ─── Test 4: admission gate refuses when free memory below threshold ─────────
echo ""
echo -e "${DIM}  admission refusal: memory threshold${RESET}"
# Make sure no lock is in the way
rm -f "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"/*.json 2>/dev/null || true
# Override memory probe to simulate low-memory host
get_free_memory_gb() { echo 2; }
output=$(check_admission_gate 2>&1) && rc=0 || rc=$?
assert_eq "admission_gate refuses on low memory" "1" "$rc"
assert_contains "diagnostic names observed free GB" "$output" "2 GB free"
assert_contains "diagnostic names min threshold" "$output" "min=4 GB"

# ─── Test 5: admission gate admits with healthy resources ────────────────────
echo ""
echo -e "${DIM}  admission success${RESET}"
get_free_memory_gb() { echo 16; }
rm -f "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"/*.json 2>/dev/null || true
if check_admission_gate >/dev/null 2>&1; then
    assert_pass "admission_gate admits healthy host"
else
    assert_fail "admission_gate admits healthy host"
fi

# ─── Test 6: stale-lock reaping ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  stale lock reaping${RESET}"
# A definitely-dead PID. Use a high number that's extremely unlikely to be alive.
dead_pid=999999
cat > "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/$dead_pid.json" <<EOF
{"pid":$dead_pid,"started_at":"2026-04-26T00:00:00Z","issue_or_goal":"crashed","repo":"/tmp/dead","pipeline_template":"standard"}
EOF
reaped=$(reap_stale_pipeline_locks)
assert_eq "reap_stale_pipeline_locks returns count >= 1" "1" "$reaped"
assert_file_not_exists "stale lock removed after reap" "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/$dead_pid.json"

# ─── Test 7: get_free_memory_gb returns a non-negative integer ───────────────
echo ""
echo -e "${DIM}  free memory probe${RESET}"
unset -f get_free_memory_gb
load_helpers >/dev/null 2>&1  # reload original implementation
free_val=$(get_free_memory_gb)
if [[ "$free_val" =~ ^[0-9]+$ ]]; then
    assert_pass "get_free_memory_gb returns non-negative integer (got $free_val)"
else
    assert_fail "get_free_memory_gb returns non-negative integer" "got: $free_val"
fi

# ─── Test 8: count_active_pipeline_locks counts correctly ────────────────────
echo ""
echo -e "${DIM}  active lock counting${RESET}"
rm -f "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"/*.json 2>/dev/null || true
empty_count=$(count_active_pipeline_locks)
assert_eq "count is 0 with empty dir" "0" "$empty_count"
echo '{"pid":1}' > "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/1.json"
echo '{"pid":2}' > "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/2.json"
two_count=$(count_active_pipeline_locks)
assert_eq "count is 2 with two lock files" "2" "$two_count"

print_test_results
