#!/usr/bin/env bash
# plugins/tool/orch-mock/plugin.sh
# Synchronous mock orchestrator backend — test-only (issue #219).
#
# Work unit definition
# --------------------
# A "work unit" is a bash function body encoded as a plain string that is safe
# to pass through $(...) and environment variables without escaping.  Callers
# build one with the orch_work_unit helper below:
#
#   unit="$(orch_work_unit 'echo hello')"
#   pool_id="test-pool-$$"
#   orch_dispatch "$pool_id" "$unit"
#   orch_collect  "$pool_id"
#
# Internally the mock stores each dispatched unit as a file under
# ${ORCH_MOCK_DIR}/<pool_id>/pending/<seq>.unit
# and writes results to
# ${ORCH_MOCK_DIR}/<pool_id>/results/<seq>.{stdout,rc}
# orch_collect reads them in order and prints the first non-zero rc + all stdout.
# orch_shutdown removes the pool directory.
#
# The mock NEVER spawns background subshells; every operation is synchronous.

[[ -n "${_ZBUILD_ORCH_MOCK_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_MOCK_LOADED=1

# Root directory for all mock state.  Tests may set ORCH_MOCK_DIR before
# sourcing; otherwise it defaults to a subdirectory under TEST_TEMP_DIR (or /tmp).
ORCH_MOCK_DIR="${ORCH_MOCK_DIR:-${TEST_TEMP_DIR:-/tmp}/orch-mock}"

# ─── orch_work_unit ──────────────────────────────────────────────────────────
# Build a work-unit string from a bash body fragment.
# Usage: unit="$(orch_work_unit 'echo "hello world"; exit 0')"
# The body must be expressible as a single-line string (no literal newlines
# in the argument).  For multi-statement bodies use semicolons.
orch_work_unit() {
    local body="$1"
    # Store as-is.  The body is what bash -c will receive.
    printf '%s' "$body"
}

# ─── _orch_mock_pool_dir ─────────────────────────────────────────────────────
_orch_mock_pool_dir() {
    local pool_id="$1"
    # Sanitize pool_id: replace characters unsafe for directory names.
    local safe_id
    safe_id="$(printf '%s' "$pool_id" | tr -cs '[:alnum:]_-' '_')"
    echo "${ORCH_MOCK_DIR}/${safe_id}"
}

# ─── orch_spawn ──────────────────────────────────────────────────────────────
# Contract: orch_spawn <pool_id> <count> <role_arg>
# Mock: creates the pool directory; count and role_arg are accepted but ignored
# because the mock runs work units as they are dispatched, not via pre-spawned
# workers.
orch_spawn() {
    local pool_id="$1"
    # $2 = count, $3 = role_arg — accepted, ignored in mock
    local pool_dir
    pool_dir="$(_orch_mock_pool_dir "$pool_id")"
    mkdir -p "${pool_dir}/pending"
    mkdir -p "${pool_dir}/results"
    # Sequence counter for ordering
    printf '0' > "${pool_dir}/seq"
}

# ─── orch_dispatch ───────────────────────────────────────────────────────────
# Contract: orch_dispatch <pool_id> <task_body>
# Mock: executes the task_body synchronously in a subshell; persists
#       stdout + exit code to results/<seq>.{stdout,rc}.
# Returns 0 (task accepted for execution); task failures surface via orch_collect.
# This matches the async contract: callers must not assume dispatch failure == task failure.
orch_dispatch() {
    local pool_id="$1"
    local task_body="$2"
    local pool_dir
    pool_dir="$(_orch_mock_pool_dir "$pool_id")"

    if [[ ! -d "${pool_dir}/pending" ]]; then
        # Auto-init pool if orch_spawn was not called explicitly.
        orch_spawn "$pool_id" 1 ""
    fi

    # Read and increment sequence counter.
    local seq
    seq="$(cat "${pool_dir}/seq" 2>/dev/null || echo 0)"
    local next_seq=$(( seq + 1 ))
    printf '%s' "$next_seq" > "${pool_dir}/seq"

    local result_dir="${pool_dir}/results"
    local stdout_file="${result_dir}/${seq}.stdout"
    local rc_file="${result_dir}/${seq}.rc"

    # Execute synchronously; capture stdout; store rc.
    local task_rc=0
    bash -c "$task_body" > "$stdout_file" 2>&1 || task_rc=$?
    printf '%s' "$task_rc" > "$rc_file"

    # Always return 0: dispatch means "task accepted", not "task succeeded".
    # Task failures are surfaced by orch_collect, preserving set -e safety.
    return 0
}

# ─── orch_collect ────────────────────────────────────────────────────────────
# Contract: orch_collect <pool_id> [--timeout S]
# Mock: iterates all result files in dispatch order; prints stdout of every
#       work unit.  Returns 0/1/2 per the orch contract (#269):
#         0 — all work units exited 0 (success)
#         1 — all work units exited non-zero (complete failure)
#         2 — mixed: at least one passed and at least one failed (partial)
#       --timeout is accepted but ignored (mock is synchronous).
orch_collect() {
    local pool_id="$1"
    # Accept --timeout flag without error; value is discarded.
    # shift remaining args — nothing to parse beyond pool_id for the mock.

    local pool_dir
    pool_dir="$(_orch_mock_pool_dir "$pool_id")"

    if [[ ! -d "${pool_dir}/results" ]]; then
        # Pool was never initialized — nothing to collect.
        return 0
    fi

    local total
    total="$(cat "${pool_dir}/seq" 2>/dev/null || echo 0)"

    local pass_count=0 fail_count=0
    local i
    for (( i = 0; i < total; i++ )); do
        local stdout_file="${pool_dir}/results/${i}.stdout"
        local rc_file="${pool_dir}/results/${i}.rc"

        if [[ -f "$stdout_file" ]]; then
            cat "$stdout_file"
        fi

        if [[ -f "$rc_file" ]]; then
            local task_rc
            task_rc="$(cat "$rc_file")"
            if [[ "$task_rc" -eq 0 ]]; then
                pass_count=$((pass_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        fi
    done

    if [[ "$fail_count" -eq 0 ]]; then
        return 0
    elif [[ "$pass_count" -gt 0 ]]; then
        return 2  # partial
    else
        return 1  # all failed
    fi
}

# ─── orch_shutdown ───────────────────────────────────────────────────────────
# Contract: orch_shutdown <pool_id>
# Mock: removes the pool directory completely.
orch_shutdown() {
    local pool_id="$1"
    local pool_dir
    pool_dir="$(_orch_mock_pool_dir "$pool_id")"
    if [[ -d "$pool_dir" ]]; then
        rm -rf "$pool_dir"
    fi
}

# ─── orch_capabilities ───────────────────────────────────────────────────────
# Contract: orch_capabilities → JSON array of declared capabilities.
# Mock: returns the capabilities declared in the manifest.
orch_capabilities() {
    printf '["sequential","fanout"]\n'
}

# ─── orch_has_capability ─────────────────────────────────────────────────────
# Convenience function checked by the contract layer (core/orch/contract.sh).
# Usage: orch_has_capability <capability_name>
# Returns 0 if the capability is present, 1 if not.
orch_has_capability() {
    local cap="$1"
    local caps
    caps="$(orch_capabilities)"
    # Simple grep-based check — no jq required for the mock.
    if grep -qF "\"${cap}\"" <<< "$caps"; then
        return 0
    fi
    return 1
}

# ─── Lifecycle hooks (used by plugin_hook_call) ───────────────────────────────
orch_mock_run() {
    # No-op for the mock; real backends would do daemon startup here.
    return 0
}
