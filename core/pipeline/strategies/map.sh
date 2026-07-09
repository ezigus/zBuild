#!/usr/bin/env bash
# core/pipeline/strategies/map.sh — data-driven map over any declared list dimension (issue #1285)
# ADR-047: generalizes fanout (platforms) to arbitrary declared dimensions.
# When dimension=platforms, behavior is byte-identical to _strategy_run_fanout.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_MAP_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_MAP_LOADED=1

_ZBUILD_STRATEGIES_DIR_MAP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ZBUILD_STRATEGIES_DIR_MAP}/common.sh"

# ─── _strategy_map_resolve_dimension ─────────────────────────────────────────
# Resolves the iteration list for the given dimension name.
# For "platforms": uses _DETECTED_PLATFORMS (set by runner before dispatch).
# For other names: uses _MAP_DIM_<name> array if set; otherwise empty.
# Prints one element per line; no output = empty dimension.
_strategy_map_resolve_dimension() {
    local dim="${1:-platforms}"
    if [[ "$dim" == "platforms" ]]; then
        local p
        for p in "${_DETECTED_PLATFORMS[@]+"${_DETECTED_PLATFORMS[@]}"}"; do
            [[ -n "$p" ]] && printf '%s\n' "$p"
        done
        return 0
    fi
    # Arbitrary dimension: caller must export _MAP_DIM_<name> as an array.
    # Validate dimension name to prevent variable-name injection.
    if [[ ! "$dim" =~ ^[a-zA-Z0-9_]{1,64}$ ]]; then
        warn "map: invalid dimension name: ${dim}" || true
        return 2
    fi
    # Read the caller's _MAP_DIM_<name> array by reference (Bash 5+ floor — see
    # scripts/lib/compat.sh). The name was validated above, guarding the target.
    # The array lives in the caller's scope (same sourced shell). Guarded
    # expansion tolerates an unset target under the caller's `set -u`.
    local -n _ref="_MAP_DIM_${dim}"
    local elem
    for elem in "${_ref[@]+"${_ref[@]}"}"; do
        [[ -n "$elem" ]] && printf '%s\n' "$elem"
    done
}

# ─── _strategy_map_resolve_max ───────────────────────────────────────────────
# Resolves the max_parallel concurrency cap for a map group.
# Input: raw max value from template (_TPL_MAP_MAX_<gid>), e.g. "4", "auto", "".
# "auto" / empty: use ZBUILD_PARALLEL_JOBS env override, else CPU count capped at 8.
# Returns the resolved integer via stdout.
_strategy_map_resolve_max() {
    local raw="${1:-}"
    local cap=8
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
        local n="$raw"
        (( n > cap )) && n=$cap
        printf '%s' "$n"
        return 0
    fi
    # "auto" or empty: mirror _parallel_resolve_max from parallel-orchestrator.sh.
    local n
    if [[ "${ZBUILD_PARALLEL_JOBS:-}" =~ ^[1-9][0-9]*$ ]]; then
        n="$ZBUILD_PARALLEL_JOBS"
    else
        n="$( { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null; } | head -1 )"
        [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=4
    fi
    (( n > cap )) && n=$cap
    printf '%s' "$n"
}

# ─── _strategy_run_map ───────────────────────────────────────────────────────
# Usage: _strategy_run_map <pool_id> <stage> <roles_out> <state_file> <plugins_root> \
#                          [dimension] [env_target] [max_parallel] [on_member_error]
#   pool_id          — caller-supplied, already validated. Used as the base for
#                      per-batch sub-pool ids ("<base>-b<N>", truncated to fit the
#                      64-char backend limit). The FIFO-batch loop below spawns and
#                      shuts down one sub-pool per batch via orch_spawn/orch_shutdown;
#                      the caller's own pool_id is also orch_shutdown at the end.
#   stage            — stage name (e.g. "intake")
#   roles_out        — newline-delimited list of role names
#   state_file       — path to pipeline state file
#   plugins_root     — path to plugins directory
#   dimension        — list name to iterate (default: "platforms")
#   env_target       — optional env var name to set to each element per work unit
#                      (issue #1295, ADR-047 §2: generic dimension→env mapping declared
#                      by the template's `as:` field; empty = no extra env). The
#                      strategy is element-name-agnostic — it never hardcodes a var name.
#   max_parallel     — concurrency cap (issue #1312): "auto"/empty = CPU-based cap;
#                      integer = explicit cap. Enforced via a FIFO-pool batch loop
#                      (mirrors ADR-039 parallel_group_run FIFO pool semantics).
#   on_member_error  — "collect" (default) or "continue" (issue #1312).
#                      continue: a failing element does NOT abort the group (return 0);
#                      collect:  any failure is propagated (return 1/2).
#                      Mirrors parallel_group_run on_member_error semantics (ADR-039).
#
# Dispatches one work unit per role×element pair.
# When dimension=platforms, behavior is byte-identical to _strategy_run_fanout.
#
# Returns:
#   0 — all succeeded, OR on_member_error=continue (even with failures)
#   1 — all failed (only when on_member_error=collect)
#   2 — partial (at least one success, at least one fail; only when on_member_error=collect)
#   3 — empty dimension (no elements to iterate; caller/runner maps to no-op 0)
#   4 — no plugin found for any role
#   5 — invalid/unknown dimension name (fail-closed; runner surfaces as failure)
#   6 — infrastructure failure (orch_spawn failed for a batch sub-pool). Fail-closed:
#       NOT subject to on_member_error — an infra failure is never a member outcome.
_strategy_run_map() {
    local pool_id="$1" stage="$2" roles_out="$3" state_file="$4" plugins_root="$5"
    local dimension="${6:-platforms}" env_target="${7:-}"
    local max_raw="${8:-}" on_member_error="${9:-collect}"
    local success_count=0 fail_count=0 any_plugin_found=false
    local state_dir; state_dir="$(dirname "$state_file")"

    # Resolve the iteration list. Capture output AND rc explicitly — a process
    # substitution would discard the resolver's status, collapsing an invalid
    # dimension (rc=2) into the empty path (rc=3) and masking a fail-closed error.
    local _resolved _res_rc
    _resolved="$(_strategy_map_resolve_dimension "$dimension")"; _res_rc=$?
    if [[ $_res_rc -ne 0 ]]; then
        # Invalid/unknown dimension name — fail closed. Distinct from empty (rc=3);
        # the runner does NOT map rc=5 to 0, so this surfaces as a real failure.
        orch_shutdown "$pool_id" 2>/dev/null || true
        return 5
    fi

    local -a elements=()
    local _elem
    while IFS= read -r _elem; do
        [[ -n "$_elem" ]] && elements+=("$_elem")
    done <<< "$_resolved"

    if [[ ${#elements[@]} -eq 0 ]]; then
        orch_shutdown "$pool_id" 2>/dev/null || true
        return 3
    fi

    # #1312: resolve the concurrency cap (mirrors ADR-039 FIFO pool).
    local max_parallel
    max_parallel="$(_strategy_map_resolve_max "$max_raw")"

    # Build the ordered list of (plugin_dir, element) work items by iterating
    # roles × elements — same order as before, just collected before dispatch.
    local -a wu_list=() plugin_list=()
    local role element plugin_dir wu
    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        for element in "${elements[@]}"; do
            # Mirror fanout.sh platform-specific then generic resolution.
            plugin_dir="$(resolve_plugin_for_role "$role" "$element" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && \
                plugin_dir="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && continue
            any_plugin_found=true

            # Only the platforms dimension populates ZBUILD_PLATFORM (ADR-009 §6
            # env contract) — pass the element as the 4th arg so the platforms
            # path stays byte-identical to fanout. For non-platform dimensions
            # (lenses/mutants), pass the generic element identity via args 5+6
            # (ZBUILD_MAP_ELEMENT / ZBUILD_MAP_DIMENSION, issue #1295, ADR-047 §2)
            # so each work unit is distinguishable without hijacking ZBUILD_PLATFORM.
            # An optional env_target (arg 7, from the template's `as:`) additionally
            # sets a named env var to the element — a generic mapping the strategy
            # applies without knowing which dimension or var it is.
            if [[ "$dimension" == "platforms" ]]; then
                wu="$(_strategy_make_work_unit "$plugin_dir" "$stage" "$state_file" "$element")"
            else
                wu="$(_strategy_make_work_unit "$plugin_dir" "$stage" "$state_file" "generic" "$element" "$dimension" "$env_target")"
            fi || {
                warn "map: failed to create work unit for role=$role element=$element" || true
                fail_count=$((fail_count + 1))
                continue
            }
            wu_list+=("$wu")
            plugin_list+=("$plugin_dir")
        done
    done <<< "$roles_out"

    if ! $any_plugin_found; then
        _strategy_cleanup_work_units "${wu_list[@]+"${wu_list[@]}"}"
        orch_shutdown "$pool_id" 2>/dev/null || true
        return 4
    fi

    # #1312: FIFO-pool batch dispatch — respects max_parallel cap (ADR-039 model).
    # Dispatch up to max_parallel work units per batch; collect before advancing.
    # This enforces the concurrency cap via the orch backend's own pool machinery.
    # Each batch uses a sub-pool so collect drains only the in-flight batch.
    # on_member_error=continue: all batches run regardless of prior batch failures.
    local total_wu="${#wu_list[@]}"
    local batch_start=0 batch_seq=0
    local infra_failed=false   # #1312: orch_spawn failure = infra error → fail-closed
    local -a batch_plugins=()
    # #1312 (Copilot): backends validate pool_id against ^[a-zA-Z0-9_-]{1,64}$.
    # The per-batch "-b<N>" suffix must not push the id past 64 chars, or orch_spawn
    # fails and the whole batch is silently skipped. Truncate the base so
    # "<base>-b<N>" always fits: reserve 10 chars for the largest realistic suffix
    # (e.g. "-b99999999"), keeping the base at ≤54 chars.
    local _sub_pool_base="$pool_id"
    if [[ ${#_sub_pool_base} -gt 54 ]]; then
        _sub_pool_base="${_sub_pool_base:0:54}"
    fi
    while [[ $batch_start -lt $total_wu ]]; do
        batch_seq=$(( batch_seq + 1 ))
        local sub_pool_id="${_sub_pool_base}-b${batch_seq}"

        # #1312 (Copilot): orch_spawn failure is an INFRASTRUCTURE failure, NOT a
        # member failure — silently skipping a batch's work units (and possibly
        # still returning 0 under on_member_error=continue) hides real breakage.
        # Fail closed: stop dispatching and propagate a non-zero rc regardless of
        # on_member_error.
        if ! orch_spawn "$sub_pool_id" 2>/dev/null; then
            warn "map: orch_spawn failed for sub-pool ${sub_pool_id} (infra failure — aborting)" || true
            infra_failed=true
            break
        fi

        batch_plugins=()
        # #1312 (Copilot): advance batch_start to the next UNPROCESSED index (i),
        # NOT by a fixed max_parallel stride. When orch_dispatch fails, batch_dispatched
        # does not increment, so the inner loop consumes more than max_parallel indices;
        # a fixed stride would then re-process or skip units. `batch_start=i` after the
        # loop guarantees every unit is dispatched exactly once.
        local batch_dispatched=0 i
        for (( i = batch_start; i < total_wu && batch_dispatched < max_parallel; i++ )); do
            wu="${wu_list[$i]}"
            orch_dispatch "$sub_pool_id" "$wu" >/dev/null || {
                warn "map: orch_dispatch failed for work unit at index $i" || true
                fail_count=$(( fail_count + 1 ))
                continue
            }
            batch_dispatched=$(( batch_dispatched + 1 ))
            batch_plugins+=("${plugin_list[$i]}")
        done
        batch_start=$i

        if [[ $batch_dispatched -gt 0 ]]; then
            local collect_rc=0
            orch_collect "$sub_pool_id" --timeout "${ZBUILD_ORCH_TIMEOUT:-300}" || collect_rc=$?

            if [[ $collect_rc -eq 0 ]]; then
                success_count=$(( success_count + 1 ))
                if declare -F _check_artifact_contract >/dev/null 2>&1; then
                    local dp
                    declare -A _seen_dp=()
                    for dp in "${batch_plugins[@]+"${batch_plugins[@]}"}"; do
                        [[ -n "${_seen_dp[$dp]:-}" ]] && continue
                        _seen_dp[$dp]=1
                        _check_artifact_contract "$dp" "$state_dir" "$stage"
                    done
                    unset _seen_dp
                fi
            elif [[ $collect_rc -eq 2 ]]; then
                success_count=$(( success_count + 1 ))
                fail_count=$(( fail_count + 1 ))
            else
                fail_count=$(( fail_count + 1 ))
            fi
        fi

        orch_shutdown "$sub_pool_id" 2>/dev/null || true
    done

    _strategy_cleanup_work_units "${wu_list[@]+"${wu_list[@]}"}"
    # Shut down the original pool_id (caller spawned it; we use sub-pools per batch
    # but the caller's pool must still be closed via orch_shutdown for contract compliance).
    orch_shutdown "$pool_id" 2>/dev/null || true

    # #1312 (Copilot): infra failure (orch_spawn) fails closed — non-zero rc, NOT
    # subject to on_member_error. rc=6 is distinct from member outcomes (0/1/2) so
    # the runner surfaces it as a real failure even under on_member_error=continue.
    if $infra_failed; then
        return 6
    fi

    # #1312: on_member_error=collect (default) — propagate failure outward (group
    # fails if any element failed). runner.sh's strategy: map/map:* call sites rely
    # on this default. on_member_error=continue mirrors parallel_group_run: all
    # elements run regardless of failures; group returns 0 even on partial/all-fail.
    if [[ "$on_member_error" == "continue" ]]; then
        return 0
    fi

    if   [[ $fail_count -eq 0 ]];    then return 0
    elif [[ $success_count -gt 0 ]]; then return 2
    else                                  return 1
    fi
}
