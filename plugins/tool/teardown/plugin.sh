#!/usr/bin/env bash
# plugins/tool/teardown/plugin.sh — Teardown plugin (ADR-054 §7, issue #1829)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
# Dispatched by the runner at every pipeline exit path with scope=release.
# Iterates over stages that executed (status=complete or status=failed) from
# pipeline-state.json and calls plugin_hook_call cleanup for each.
# A plugin with no cleanup hook returns 0 and emits `plugin.cleanup.absent`
# (#1823) — nothing to free is not a failure, so it needs no special case here.
# Always exits 0 — teardown failures are events, not verdict changes.

[[ -n "${_ZBUILD_TEARDOWN_LOADED:-}" ]] && return 0
_ZBUILD_TEARDOWN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_ZBUILD_TEARDOWN_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_TEARDOWN_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_TEARDOWN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_ZBUILD_TEARDOWN_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../../core/pipeline/dispatch.sh
# resolve_stage_plugin lives here; declare it rather than inherit the runner's
# scope — without it any other caller frees nothing and still returns 0.
source "$_ZBUILD_TEARDOWN_ROOT/core/pipeline/dispatch.sh"

# ─── teardown_run ────────────────────────────────────────────────────────────
# Entry point called by the pipeline engine.
# Usage: teardown_run <stage_id> <state_file>
# Scope is read from ZBUILD_TEARDOWN_SCOPE (default: release).
teardown_run() {
    local _stage_id="${1:-teardown}"
    local _state_file="${2:-}"

    # Fail-safe: an unrecognised scope degrades to `release`, the scope that
    # deletes nothing. The destructive scope is never the fallback.
    local _scope="${ZBUILD_TEARDOWN_SCOPE:-release}"
    case "$_scope" in
        release|purge) ;;
        *)
            emit_event "teardown.scope.invalid" \
                "requested=$_scope" "used=release" 2>/dev/null || true
            _scope="release"
            ;;
    esac
    local _plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_TEARDOWN_ROOT/plugins}"

    local _state_dir=""
    [[ -n "$_state_file" ]] && _state_dir="$(dirname "$_state_file")"

    # Read stages that executed (complete or failed) from pipeline-state.json.
    local -a _executed=()
    if [[ -n "$_state_file" && -f "$_state_file" ]]; then
        local _s
        while IFS= read -r _s; do
            [[ -n "$_s" ]] && _executed+=("$_s")
        # NB: the durable key is `stage_statuses` and its values are plain
        # strings, not objects. Reading `.stages[].status` (which no state file
        # has ever had) yields an empty list, which makes teardown a silent
        # no-op that still reports success — verified against a real run's
        # pipeline-state.json before this was corrected.
        done < <(jq -r '
            .stage_statuses // {} |
            to_entries[] |
            select(.value == "complete" or .value == "failed") |
            .key
        ' "$_state_file" 2>/dev/null || true)
    fi

    # ADR-062 §2: union in every stage recorded at DISPATCH.
    #
    # stage_statuses is written by _update_stage_status only on complete/failed
    # — after a stage RETURNS. A stage killed mid-flight never returns, so it
    # never appeared above and was never released: the external-signal paths
    # freed `intake` only while `build` was demonstrably running (#1748, #2001).
    #
    # runtime/stages/<stage>.pgid is written by plugin_hook_call at dispatch
    # (ADR-058 §1's declared purpose for runtime/), so it exists for exactly the
    # stages that started, whether or not they finished.
    if [[ -n "$_state_dir" && -d "$_state_dir/runtime/stages" ]]; then
        local _pgf _pgstage _seen
        for _pgf in "$_state_dir"/runtime/stages/*.pgid; do
            [[ -e "$_pgf" ]] || continue
            _pgstage="$(basename "$_pgf" .pgid)"
            _seen=0
            for _s in "${_executed[@]+"${_executed[@]}"}"; do
                [[ "$_s" == "$_pgstage" ]] && { _seen=1; break; }
            done
            [[ "$_seen" -eq 0 ]] && _executed+=("$_pgstage")
        done
    fi

    # ── dry-run fast path ─────────────────────────────────────────────────────
    # When ZBUILD_CLEAN_DRY_RUN=1 (set by `zbuild clean --dry-run`), emit a
    # teardown.dry_run.would_clean event for each stage that WOULD be cleaned
    # and return 0 without invoking any cleanup hooks.
    if [[ "${ZBUILD_CLEAN_DRY_RUN:-0}" == "1" ]]; then
        local _s
        for _s in "${_executed[@]}"; do
            [[ "$_s" == "teardown" ]] && continue
            emit_event "teardown.dry_run.would_clean" \
                "stage=$_s" "scope=$_scope" 2>/dev/null || true
        done
        emit_event "teardown.complete" \
            "scope=$_scope" "failed=0" "dry_run=1" 2>/dev/null || true
        return 0
    fi

    emit_event "teardown.start" \
        "scope=$_scope" "stage_count=${#_executed[@]}" 2>/dev/null || true

    # ADR-062 §2: on `release`, the ENGINE kills the process groups recorded at
    # dispatch. This is what a per-stage hook was for, and it is strictly better
    # here: the record is on disk, so a stage that was killed before it could
    # run any hook is still freed. `release` deletes nothing — ADR-054 §7's rule
    # is unchanged and load-bearing: a failed run keeps its complete evidence.
    #
    # tool/test proved the pattern privately (test-stage.pgid + zbuild_pg_kill);
    # this is the same mechanism applied to every dispatched stage.
    if [[ "$_scope" == "release" && -n "$_state_dir" && -d "$_state_dir/runtime/stages" ]]; then
        if ! declare -F zbuild_pg_kill >/dev/null 2>&1; then
            # shellcheck source=../../../scripts/lib/proc-group.sh
            source "$_ZBUILD_TEARDOWN_ROOT/scripts/lib/proc-group.sh" 2>/dev/null || true
        fi
        local _kpgf _kpgid _killed=0
        for _kpgf in "$_state_dir"/runtime/stages/*.pgid; do
            [[ -e "$_kpgf" ]] || continue
            _kpgid="$(cat "$_kpgf" 2>/dev/null || true)"
            [[ "$_kpgid" =~ ^[0-9]+$ ]] || continue
            # Never signal our own group: teardown runs inside the run's process
            # group, so killing it would take the runner down with the stages.
            local _self_pg; _self_pg="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
            [[ "$_kpgid" == "$_self_pg" ]] && continue
            if declare -F zbuild_pg_kill >/dev/null 2>&1; then
                zbuild_pg_kill "$_kpgid" 2>/dev/null || true
                _killed=$(( _killed + 1 ))
            fi
        done
        [[ "$_killed" -gt 0 ]] && emit_event "teardown.pgroups.killed" \
            "scope=$_scope" "count=$_killed" 2>/dev/null || true
    fi

    # Derive artifacts dir from state_file (ADR-054 §2: plugins derive artifacts_dir
    # from dirname($state_file)/artifacts). Fall back to ZBUILD_ARTIFACT_DIR or tmp.
    local _artifacts_dir
    if [[ -n "$_state_file" ]]; then
        _artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$(dirname "$_state_file")/artifacts}"
    else
        _artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-teardown-artifacts}"
    fi
    mkdir -p "$_artifacts_dir"
    local _result_file="$_artifacts_dir/teardown-result.json"

    local _any_failed=0
    # Per-target outcome array: each entry is a JSON object string.
    local -a _targets=()
    local _stage _plugin_dir _rc _cleanup_fn
    for _stage in "${_executed[@]}"; do
        # Skip teardown itself to prevent circular cleanup dispatch.
        [[ "$_stage" == "teardown" ]] && continue

        _plugin_dir="$(resolve_stage_plugin "$_stage" "$_plugins_root" 2>/dev/null || true)"
        if [[ -z "$_plugin_dir" ]]; then
            _targets+=("{\"stage\":$(printf '%s' "$_stage" | jq -Rc .),\"outcome\":\"no_op\"}")
            continue
        fi

        # Check if a cleanup hook is declared — absent hook is a no_op, not a failure.
        _cleanup_fn="$(yaml_get "$_plugin_dir/manifest.yaml" "hooks.cleanup" 2>/dev/null || true)"
        if [[ -z "$_cleanup_fn" ]]; then
            # Emit the absence event (mirrors lifecycle.sh behaviour for callers
            # that bypassed plugin_hook_call, e.g. in tests).
            emit_event "plugin.cleanup.absent" \
                "stage=$_stage" 2>/dev/null || true
            _targets+=("{\"stage\":$(printf '%s' "$_stage" | jq -Rc .),\"outcome\":\"no_op\"}")
            continue
        fi

        _rc=0
        set +e
        plugin_hook_call "$_plugin_dir" cleanup "$_stage" "$_state_file" "$_scope"
        _rc=$?
        set -e

        if [[ $_rc -ne 0 ]]; then
            emit_event "stage.cleanup.failed" \
                "stage=$_stage" "scope=$_scope" "rc=$_rc" 2>/dev/null || true
            _any_failed=1
            _targets+=("{\"stage\":$(printf '%s' "$_stage" | jq -Rc .),\"outcome\":\"failed\"}")
        else
            _targets+=("{\"stage\":$(printf '%s' "$_stage" | jq -Rc .),\"outcome\":\"ok\"}")
        fi
    done

    # Build the data.targets JSON array from collected entries.
    local _targets_json="["
    local _i
    for (( _i=0; _i<${#_targets[@]}; _i++ )); do
        [[ $_i -gt 0 ]] && _targets_json+=","
        _targets_json+="${_targets[$_i]}"
    done
    _targets_json+="]"

    local _verdict _reason
    if [[ $_any_failed -eq 0 ]]; then
        _verdict="complete"
        _reason="all cleanup hooks completed without error"
    else
        _verdict="degraded"
        _reason="one or more cleanup hooks returned non-zero; see stage.cleanup.failed events"
    fi

    # Write the v2 result file (ADR-054 §5, ADR-055). Guarded: the loop above
    # re-enables errexit, so an unguarded pipe would abort teardown_run here on
    # a failed write — before teardown.complete and before the `return 0` that
    # ADR-054 §4 requires. The runner's EXIT-trap call site hides that today
    # (runner.sh backgrounds the hook inside `|| true`), which only converts it
    # into a silent loss of both the result and the completion event; dispatched
    # as an ordinary stage (#1831) the rc would escape. Failure rides an event,
    # like every other teardown failure.
    if ! printf '%s\n' "{
  \"result_contract\": 2,
  \"verdict\": \"$_verdict\",
  \"disposition\": \"complete\",
  \"reason\": \"$_reason\",
  \"data\": {
    \"targets\": $_targets_json
  }
}" | atomic_write "$_result_file"; then
        emit_event "teardown.result.write_failed" \
            "file=$_result_file" "scope=$_scope" 2>/dev/null || true
    fi

    # ADR-055 §9: teardown always returns 0, so its summary is the only place a
    # failed cleanup is stated as such rather than inferred from an event.
    stage_summary_write "$(dirname "$_result_file")/teardown-summary.md" "teardown" "$_verdict" \
        "cleaned up scope $_scope" \
        "$(printf -- '- failures: %s\n- detail: %s' "$_any_failed" "${_reason:-none}")"
    emit_event "teardown.complete" \
        "scope=$_scope" "failed=$_any_failed" 2>/dev/null || true
    # Always return 0: cleanup failures are recorded via events, not propagated.
    return 0
}
