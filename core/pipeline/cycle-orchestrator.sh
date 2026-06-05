#!/usr/bin/env bash
# core/pipeline/cycle-orchestrator.sh — ADR-021 outer-cycle orchestrator (F1)
#
# F1 = foundational framework + flag-gated stub. NO concrete cycle wired in
# config/templates/standard.yaml (F2/#511 does that). Runner only enters the
# cycle branch when ZBUILD_CYCLES_ENABLED=1 AND a `cycles:` overlay is parsed.
#
# Public surface:
#   cycle_orchestrator_run <cycle_id> <state_dir> <state_file>
#     rc: 0=converged, 1=max_iterations, 2=plateau, 3=divergence,
#         130=aborted, 4=config_invalid (template error)
#     Sets globals:
#       _CYCLE_LAST_TERMINATED_REASON  string enum
#       _CYCLE_LAST_ITERATIONS         int
#       _CYCLE_LAST_HISTORY_FILE       absolute path
#
# Internal helpers (prefix `_cycle_`):
#   _cycle_load_template / _cycle_iter_dispatch / _cycle_install_traps /
#   _cycle_clear_traps   / _cycle_on_signal     / _cycle_record_iter_outcome /
#   _cycle_check_until   / _cycle_check_max_iterations /
#   _cycle_detect_plateau / _cycle_detect_divergence /
#   _cycle_apply_feedback / _cycle_handle_terminal_rc
#
# Sourced library: do not add `set -euo pipefail` here.

[[ -n "${_ZBUILD_CYCLE_ORCH_LOADED:-}" ]] && return 0
_ZBUILD_CYCLE_ORCH_LOADED=1

_CYCLE_ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CYCLE_ORCH_ROOT="$(cd "$_CYCLE_ORCH_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_CYCLE_ORCH_ROOT/scripts/lib/helpers.sh"
# ADR-025 (Wave 15-B #684) abort-propagation contract helpers.
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$_CYCLE_ORCH_ROOT/scripts/lib/abort-propagation.sh"
# shellcheck source=../state/atomic.sh
source "$_CYCLE_ORCH_ROOT/core/state/atomic.sh"
# shellcheck source=../state/resume.sh
source "$_CYCLE_ORCH_ROOT/core/state/resume.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_CYCLE_ORCH_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=./template.sh
source "$_CYCLE_ORCH_ROOT/core/pipeline/template.sh"
# shellcheck source=../output/event-banners.sh
# #526: operator-visible WARN banner for HIGH-severity cycle events.
source "$_CYCLE_ORCH_ROOT/core/output/event-banners.sh"
# #511 F2 Pin 2: resolve feedback source paths via the from-stage manifest's
# outputs[id==<X>].path entry (so the orchestrator stops assuming the legacy
# `artifacts/<stage>/<output>` layout that real plugins do NOT follow).
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$_CYCLE_ORCH_ROOT/scripts/lib/manifest-graph.sh"

# ─── Constants ────────────────────────────────────────────────────────────────
# HARDCODED ceiling — checked BEFORE the template's max_iterations value (silent-
# failure guard #2). Templates that ask for more get clamped + emit config.invalid.
readonly _CYCLE_ABSOLUTE_MAX=10

# Default convergence-detection windows (overridable per cycle in template).
readonly _CYCLE_DEFAULT_PLATEAU_WINDOW=3
readonly _CYCLE_DEFAULT_DIVERGENCE_WINDOW=2

# ─── Public globals (set by cycle_orchestrator_run) ──────────────────────────
_CYCLE_LAST_TERMINATED_REASON=""
_CYCLE_LAST_ITERATIONS=0
_CYCLE_LAST_HISTORY_FILE=""

# Internal trap-state (mirrors _route_loop_* convention in route.sh).
_CYCLE_TRAP_CYCLE_ID=""
_CYCLE_TRAP_ITER=0
_CYCLE_TRAP_HISTORY_FILE=""

# ─── Per-iter start-wall-clock cache (#524) ──────────────────────────────────
# Populated by the iter-begin hook (orchestrator) and read by the iter-complete
# hook to compute elapsed_s for the operator-visible iter-complete trailer.
# Keyed by iter number; values are ms epochs.
declare -gA _CYCLE_ITER_START_MS=()

# ─── _cycle_emit — wrapper around eb_emit_event with cycle envelope ──────────
# Adds cycle_id automatically; payload is flat k=v per zbuild convention.
# #526: also dispatches to the HIGH-event banner emitter so the 5 high-severity
# cycle.* events fire both a JSONL record (durable) AND a stderr WARN banner
# (operator-visible). Banner is a no-op for non-HIGH event types — see
# core/output/event-banners.sh::_HIGH_EVENT_TYPES.
_cycle_emit() {
    local type="$1"; shift
    eb_emit_event "$type" "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" "$@" \
        2>/dev/null || true
    # Banner intentionally writes to stderr — do NOT redirect 2>/dev/null here.
    # The helper itself wraps its body in best-effort guards.
    _emit_high_event_banner "$type" "$@" || true
}

# ─── Trap composition (silent-failure findings #5, #6) ───────────────────────
# Cycle owns ONLY INT/TERM. Runner owns EXIT. On signal: emit cycle.aborted,
# clear traps, return 130. Must be re-installed after each stage dispatch
# because route.sh::_route_loop_install_traps clobbers without saving.
_cycle_install_traps() {
    trap '_cycle_on_signal SIGINT' INT
    trap '_cycle_on_signal SIGTERM' TERM
}
_cycle_clear_traps() {
    trap - INT TERM
}
_cycle_on_signal() {
    local sig="$1"
    _CYCLE_LAST_TERMINATED_REASON="aborted"
    eb_emit_event "cycle.aborted" \
        "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" \
        "iter=${_CYCLE_TRAP_ITER}" \
        "signal=$sig" 2>/dev/null || true
    _cycle_clear_traps
    return 130
}

# ─── _cycle_load_template <cycle_id> ─────────────────────────────────────────
# Reads template-parser cycle vars set by template.sh::_tpl_parse_cycle_data.
# Validates max_iterations bounds + required fields. Populates:
#   _CYCLE_STAGES[]     (contiguous subsequence of canonical stages)
#   _CYCLE_MAX_ITER     (integer 1.._CYCLE_ABSOLUTE_MAX)
#   _CYCLE_ON_MAX       (continue|halt)
#   _CYCLE_UNTIL_STAGE  (id within _CYCLE_STAGES)
#   _CYCLE_UNTIL_FIELD  (verdict|status)
#   _CYCLE_UNTIL_OP     (eq|ne)
#   _CYCLE_UNTIL_VALUE  (string)
#   _CYCLE_PLATEAU_WINDOW / _CYCLE_DIVERGENCE_WINDOW
#   _CYCLE_FEEDBACK[]   (flat list: "from_stage:from_output:to_stage:to_field:required")
# Returns: 0 valid; 4 invalid (emits cycle.config.invalid).
_cycle_load_template() {
    local cycle_id="$1"
    local safe="${cycle_id//-/_}"

    _CYCLE_STAGES=()
    _CYCLE_FEEDBACK=()
    _CYCLE_MAX_ITER=""
    _CYCLE_ON_MAX="continue"
    _CYCLE_UNTIL_STAGE=""
    _CYCLE_UNTIL_FIELD=""
    _CYCLE_UNTIL_OP=""
    _CYCLE_UNTIL_VALUE=""
    _CYCLE_PLATEAU_WINDOW="$_CYCLE_DEFAULT_PLATEAU_WINDOW"
    _CYCLE_DIVERGENCE_WINDOW="$_CYCLE_DEFAULT_DIVERGENCE_WINDOW"

    # Pull from template-parser side-channel vars.
    local stages_var="_TPL_CYCLE_STAGES_${safe}"
    local max_var="_TPL_CYCLE_MAX_${safe}"
    local on_max_var="_TPL_CYCLE_ON_MAX_${safe}"
    local us_var="_TPL_CYCLE_UNTIL_STAGE_${safe}"
    local uf_var="_TPL_CYCLE_UNTIL_FIELD_${safe}"
    local uo_var="_TPL_CYCLE_UNTIL_OP_${safe}"
    local uv_var="_TPL_CYCLE_UNTIL_VALUE_${safe}"
    local pw_var="_TPL_CYCLE_PLATEAU_W_${safe}"
    local dw_var="_TPL_CYCLE_DIVERGENCE_W_${safe}"
    local fb_var="_TPL_CYCLE_FEEDBACK_${safe}"

    local stages_csv="${!stages_var:-}"
    if [[ -z "$stages_csv" ]]; then
        error "cycle '$cycle_id': no stages declared"
        _cycle_emit "cycle.config.invalid" "reason=no_stages"
        return 4
    fi
    local IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    _CYCLE_STAGES=($stages_csv)
    IFS="$IFS_save"

    _CYCLE_MAX_ITER="${!max_var:-}"
    if [[ -z "$_CYCLE_MAX_ITER" ]] || ! [[ "$_CYCLE_MAX_ITER" =~ ^[0-9]+$ ]]; then
        error "cycle '$cycle_id': max_iterations required (integer 1..${_CYCLE_ABSOLUTE_MAX})"
        _cycle_emit "cycle.config.invalid" "reason=max_iterations_missing_or_nonint" \
            "value=${_CYCLE_MAX_ITER:-<unset>}"
        return 4
    fi
    if [[ "$_CYCLE_MAX_ITER" -lt 1 || "$_CYCLE_MAX_ITER" -gt "$_CYCLE_ABSOLUTE_MAX" ]]; then
        error "cycle '$cycle_id': max_iterations must be 1..${_CYCLE_ABSOLUTE_MAX}, got: $_CYCLE_MAX_ITER"
        _cycle_emit "cycle.config.invalid" "reason=max_iterations_out_of_range" \
            "value=$_CYCLE_MAX_ITER" "absolute_max=$_CYCLE_ABSOLUTE_MAX"
        return 4
    fi

    _CYCLE_ON_MAX="${!on_max_var:-continue}"
    if [[ "$_CYCLE_ON_MAX" != "continue" && "$_CYCLE_ON_MAX" != "halt" ]]; then
        error "cycle '$cycle_id': on_max must be continue|halt, got: $_CYCLE_ON_MAX"
        _cycle_emit "cycle.config.invalid" "reason=on_max_invalid" \
            "value=$_CYCLE_ON_MAX"
        return 4
    fi

    _CYCLE_UNTIL_STAGE="${!us_var:-}"
    _CYCLE_UNTIL_FIELD="${!uf_var:-}"
    _CYCLE_UNTIL_OP="${!uo_var:-}"
    _CYCLE_UNTIL_VALUE="${!uv_var:-}"

    if [[ -z "$_CYCLE_UNTIL_STAGE" || -z "$_CYCLE_UNTIL_FIELD" \
          || -z "$_CYCLE_UNTIL_OP" || -z "$_CYCLE_UNTIL_VALUE" ]]; then
        error "cycle '$cycle_id': until.{stage,field,op,value} all required"
        _cycle_emit "cycle.config.invalid" "reason=until_incomplete"
        return 4
    fi
    # v1 whitelist
    case "$_CYCLE_UNTIL_FIELD" in
        verdict|status) ;;
        *)
            error "cycle '$cycle_id': until.field must be verdict|status, got: $_CYCLE_UNTIL_FIELD"
            _cycle_emit "cycle.config.invalid" "reason=until_field_invalid" \
                "value=$_CYCLE_UNTIL_FIELD"
            return 4
            ;;
    esac
    case "$_CYCLE_UNTIL_OP" in
        eq|ne) ;;
        *)
            error "cycle '$cycle_id': until.op must be eq|ne, got: $_CYCLE_UNTIL_OP"
            _cycle_emit "cycle.config.invalid" "reason=until_op_invalid" \
                "value=$_CYCLE_UNTIL_OP"
            return 4
            ;;
    esac
    # until.stage must be in cycle.stages
    local _us_ok=0 s
    for s in "${_CYCLE_STAGES[@]}"; do
        [[ "$s" == "$_CYCLE_UNTIL_STAGE" ]] && _us_ok=1 && break
    done
    if [[ $_us_ok -ne 1 ]]; then
        error "cycle '$cycle_id': until.stage '$_CYCLE_UNTIL_STAGE' is not in cycle stages (${_CYCLE_STAGES[*]})"
        _cycle_emit "cycle.config.invalid" "reason=until_stage_outside_cycle" \
            "value=$_CYCLE_UNTIL_STAGE"
        return 4
    fi

    local pw="${!pw_var:-}"; [[ -n "$pw" && "$pw" =~ ^[0-9]+$ ]] && _CYCLE_PLATEAU_WINDOW="$pw"
    local dw="${!dw_var:-}"; [[ -n "$dw" && "$dw" =~ ^[0-9]+$ ]] && _CYCLE_DIVERGENCE_WINDOW="$dw"

    # Feedback: pipe-delimited records "from_stage:from_output|to_stage:to_field:required"
    local fb_blob="${!fb_var:-}"
    if [[ -n "$fb_blob" ]]; then
        local IFS_save2="$IFS"; IFS=$'\n'
        # shellcheck disable=SC2206
        _CYCLE_FEEDBACK=($fb_blob)
        IFS="$IFS_save2"
    fi

    return 0
}

# ─── _cycle_record_iter_outcome ──────────────────────────────────────────────
# Appends a JSONL row to the per-cycle history file. Schema:
#   {"n":N,"verdict":..,"status":..,"failure_count":N,"ts":"..."}
# Failure to write is HIGH severity — emit cycle.history.lost and propagate.
_cycle_record_iter_outcome() {
    local history_file="$1" n="$2" verdict="$3" status="$4" failure_count="$5"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
    local line
    line="$(jq -nc \
        --argjson n "$n" \
        --arg verdict "$verdict" \
        --arg status "$status" \
        --argjson fc "$failure_count" \
        --arg ts "$ts" \
        '{n:$n, verdict:$verdict, status:$status, failure_count:$fc, ts:$ts}' \
        2>/dev/null)" || {
        _cycle_emit "cycle.history.lost" "iter=$n" "reason=jq_render_failed"
        return 1
    }
    mkdir -p "$(dirname "$history_file")" 2>/dev/null || true
    if ! printf '%s\n' "$line" >> "$history_file" 2>/dev/null; then
        _cycle_emit "cycle.history.lost" "iter=$n" "reason=append_failed" \
            "history_file=$history_file"
        return 1
    fi
    return 0
}

# ─── _cycle_check_until <stage_verdicts_jsonblob> ────────────────────────────
# Returns 0 if predicate satisfied (converged), 1 otherwise.
# Stage-verdicts blob is JSON: {"<stage>":{"verdict":"pass","status":"complete"}}.
# Field-missing → 1 (NEVER falsely converge). Emits verdict_missing once.
_cycle_check_until() {
    local blob="$1"
    local stage="$_CYCLE_UNTIL_STAGE"
    local field="$_CYCLE_UNTIL_FIELD"
    local op="$_CYCLE_UNTIL_OP"
    local expected="$_CYCLE_UNTIL_VALUE"
    local actual
    actual="$(jq -r --arg s "$stage" --arg f "$field" \
        '.[$s][$f] // empty' <<< "$blob" 2>/dev/null || true)"
    if [[ -z "$actual" || "$actual" == "null" ]]; then
        _cycle_emit "cycle.iteration.verdict_missing" \
            "iter=$_CYCLE_TRAP_ITER" "stage=$stage" "field=$field"
        return 1
    fi
    case "$op" in
        eq) [[ "$actual" == "$expected" ]] && return 0 ;;
        ne) [[ "$actual" != "$expected" ]] && return 0 ;;
    esac
    return 1
}

# ─── _cycle_check_abort_when <verdicts_blob> ─────────────────────────────────
# ADR-027 (Wave 17-B #703). Mirrors _cycle_check_until against the per-cycle
# _TPL_CYCLE_ABORT_WHEN_* fields. Returns 0 if predicate fired (abort), else 1.
# Missing field → 1 (NEVER spuriously abort). No event-emit here — the caller
# in cycle_orchestrator_run emits cycle.complete reason=cycle_abort via the
# terminal-rc fan-in.
_cycle_check_abort_when() {
    local blob="$1"
    local safe="${_CYCLE_TRAP_CYCLE_ID//-/_}"
    local stage_var="_TPL_CYCLE_ABORT_WHEN_STAGE_${safe}"
    local stage="${!stage_var:-}"
    local field_var="_TPL_CYCLE_ABORT_WHEN_FIELD_${safe}"
    local field="${!field_var:-}"
    local op_var="_TPL_CYCLE_ABORT_WHEN_OP_${safe}"
    local op="${!op_var:-}"
    local val_var="_TPL_CYCLE_ABORT_WHEN_VALUE_${safe}"
    local expected="${!val_var:-}"
    [[ -z "$stage" || -z "$field" || -z "$op" || -z "$expected" ]] && return 1
    local actual
    actual="$(jq -r --arg s "$stage" --arg f "$field" \
        '.[$s][$f] // empty' <<< "$blob" 2>/dev/null || true)"
    [[ -z "$actual" || "$actual" == "null" ]] && return 1
    case "$op" in
        eq) [[ "$actual" == "$expected" ]] && return 0 ;;
        ne) [[ "$actual" != "$expected" ]] && return 0 ;;
    esac
    return 1
}

# ─── _cycle_check_max_iterations <iter> <max> ────────────────────────────────
# Strict `iter >= max` → terminate. NO auto-extend.
_cycle_check_max_iterations() {
    local iter="$1" max="$2"
    if ! [[ "$iter" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
        _cycle_emit "cycle.metric.invalid" "iter=$iter" "max=$max" \
            "reason=non_numeric"
        return 0  # treat as terminate-now, fail-closed
    fi
    [[ "$iter" -ge "$max" ]]
}

# ─── _cycle_detect_plateau <history_file> <window> ───────────────────────────
# N consecutive iterations with identical verdict tuple → plateau.
# Skip + emit cycle.plateau.skipped when iter<2 OR history_lines<N.
_cycle_detect_plateau() {
    local history_file="$1" window="$2"
    if ! [[ "$window" =~ ^[0-9]+$ ]] || [[ "$window" -lt 2 ]]; then
        _cycle_emit "cycle.metric.invalid" "metric=plateau_window" "value=$window"
        return 1
    fi
    if [[ "$_CYCLE_TRAP_ITER" -lt 2 ]]; then
        _cycle_emit "cycle.plateau.skipped" "iter=$_CYCLE_TRAP_ITER" \
            "reason=insufficient_history"
        return 1
    fi
    local lines=0
    [[ -f "$history_file" ]] && lines="$(wc -l < "$history_file" 2>/dev/null | tr -d ' ')"
    if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -lt "$window" ]]; then
        _cycle_emit "cycle.plateau.skipped" "iter=$_CYCLE_TRAP_ITER" \
            "reason=insufficient_history" "have=$lines" "need=$window"
        return 1
    fi
    # Examine last `window` rows. Plateau if all verdict tuples are identical.
    local tail_rows; tail_rows="$(tail -n "$window" "$history_file" 2>/dev/null)"
    local distinct
    distinct="$(printf '%s\n' "$tail_rows" | jq -r '"\(.verdict)|\(.status)|\(.failure_count)"' 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    [[ "$distinct" == "1" ]]
}

# ─── _cycle_detect_blocked <verdicts_blob> <iter> ────────────────────────────
# #528 — early-abort when any stage in _CYCLE_STAGES[] this iter has raw
# verdict ∈ {error, corrupt_diff, block} (the "cannot-recover" class).
#
# Returns: 0 = blocked (terminate-now), 1 = not blocked.
#
# Pin (silent-failure CRITICAL #1): blocked = verdict-PRESENT + value-in-set.
#   verdict=missing is handled exclusively by cycle.iteration.verdict_missing
#   emitted from _cycle_check_until — DO NOT double-emit.
# Pin (silent-failure CRITICAL #2): distinct from cycle.feedback.missing (#526).
#   Blocked fires on verdict; feedback.missing fires on missing-artifact.
# Pin (silent-failure HIGH #5): no debounce — these are structural failures
#   (corrupt patch, dispatch error) and retry doesn't help. EXCEPT: bypass
#   blocked when _CYCLE_UNTIL_VALUE == "error" (operator template explicitly
#   converging on error).
# Pin (silent-failure HIGH #6): jq parse failure OR empty blob → fail-CLOSED,
#   treat as terminate-now (mirrors _cycle_check_max_iterations non-numeric).
# Pin (HIGH #7): read from $1 (caller passes _CYCLE_LAST_VERDICTS_BLOB), NEVER
#   from history — resume-safe by construction.
_cycle_detect_blocked() {
    local blob="$1" iter="$2"
    # Operator-bypass: if until-value is explicitly "error", the template is
    # converging ON error — let until fire, don't shadow it.
    if [[ "${_CYCLE_UNTIL_VALUE:-}" == "error" ]]; then
        return 1
    fi
    # Fail-CLOSED: empty / unset blob.
    if [[ -z "$blob" || "$blob" == "{}" ]]; then
        _cycle_emit "cycle.metric.invalid" "metric=verdicts_blob_empty" \
            "iter=$iter"
        return 0
    fi
    # Fail-CLOSED: jq parse failure on the blob itself.
    if ! jq -e . <<< "$blob" >/dev/null 2>&1; then
        _cycle_emit "cycle.metric.invalid" "metric=blocked_eval" \
            "iter=$iter" "reason=jq_failed"
        return 0
    fi
    local s v
    for s in "${_CYCLE_STAGES[@]}"; do
        v="$(jq -r --arg s "$s" '.[$s].verdict // empty' <<< "$blob" 2>/dev/null || true)"
        case "$v" in
            error|corrupt_diff|block)
                # Stash matched stage/verdict so caller can emit cycle.blocked
                # with the originating context (event ordering MED #9).
                _CYCLE_BLOCKED_STAGE="$s"
                _CYCLE_BLOCKED_VERDICT="$v"
                return 0
                ;;
        esac
    done
    return 1
}

# ─── _cycle_detect_divergence <history_file> <K> ─────────────────────────────
# K consecutive POSITIVE failure_count deltas → divergence.
# Skip when iter<K+1.
_cycle_detect_divergence() {
    local history_file="$1" k="$2"
    if ! [[ "$k" =~ ^[0-9]+$ ]] || [[ "$k" -lt 1 ]]; then
        _cycle_emit "cycle.metric.invalid" "metric=divergence_window" "value=$k"
        return 1
    fi
    if [[ "$_CYCLE_TRAP_ITER" -lt $(( k + 1 )) ]]; then
        return 1
    fi
    local lines=0
    [[ -f "$history_file" ]] && lines="$(wc -l < "$history_file" 2>/dev/null | tr -d ' ')"
    if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -lt $(( k + 1 )) ]]; then
        return 1
    fi
    # Tail K+1 failure_counts; check K consecutive positive deltas.
    local tail_rows; tail_rows="$(tail -n $(( k + 1 )) "$history_file" 2>/dev/null)"
    local -a fcs=()
    local row
    while IFS= read -r row; do
        local v; v="$(jq -r '.failure_count // 0' <<< "$row" 2>/dev/null)"
        if ! [[ "$v" =~ ^[0-9]+$ ]]; then
            _cycle_emit "cycle.metric.invalid" "metric=failure_count" "value=$v"
            return 1
        fi
        fcs+=("$v")
    done <<< "$tail_rows"
    [[ ${#fcs[@]} -lt $(( k + 1 )) ]] && return 1
    local i
    for (( i=1; i<${#fcs[@]}; i++ )); do
        local prev="${fcs[$(( i - 1 ))]}" cur="${fcs[$i]}"
        if (( cur - prev <= 0 )); then
            return 1
        fi
    done
    return 0
}

# ─── _cycle_apply_feedback <iter_next> ───────────────────────────────────────
# Wires file-path feedback for the NEXT iteration. Layout:
#   ${state_dir}/cycle-<id>/iter-<N>/feedback/<to_field>.txt
# FAIL LOUDLY (emit cycle.feedback.missing) when from-field artifact missing.
# Never substitute empty string silently.
# ─── _cycle_resolve_from_path <state_dir> <from_stage> <from_output> ─────────
# #511 Pin 2: resolve the feedback source path using the from-stage manifest's
# outputs[id==<from_output>].path entry (which already supports ${artifact_dir}
# templating), NOT the legacy hardcoded `artifacts/<stage>/<output>` shape.
# Real plugins (build, test) write FLAT (e.g. artifacts/test-failures-summary.md),
# so the old code silently failed to find anything. Backwards-compat fallback:
# if the manifest is not available OR declares no path for the requested output
# id, fall back to `artifacts/<from_stage>/<from_output>` (legacy mock layout).
_cycle_resolve_from_path() {
    local state_dir="$1" from_stage="$2" from_output="$3"
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_CYCLE_ORCH_ROOT/plugins}"
    local manifest=""
    if declare -F manifest_graph_collect >/dev/null 2>&1; then
        manifest="$(manifest_graph_collect "$plugins_root" "$from_stage" 2>/dev/null || true)"
    fi
    if [[ -n "$manifest" && -f "$manifest" ]] \
       && declare -F manifest_graph_get_outputs >/dev/null 2>&1; then
        local rec o_id o_type o_src o_req o_path
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            # shellcheck disable=SC2034  # o_type/o_src/o_req destructured for schema parity, only o_path read
            IFS='|' read -r o_id o_type o_src o_req o_path <<< "$rec"
            if [[ "$o_id" == "$from_output" && -n "$o_path" ]]; then
                # Expand canonical templating vars.
                local resolved="$o_path"
                resolved="${resolved//\$\{artifact_dir\}/$state_dir/artifacts}"
                resolved="${resolved//\$\{state_dir\}/$state_dir}"
                printf '%s\n' "$resolved"
                return 0
            fi
        done < <(manifest_graph_get_outputs "$manifest")
    fi
    # Legacy fallback (mock plugins / pre-F2 fixtures).
    printf '%s/artifacts/%s/%s\n' "$state_dir" "$from_stage" "$from_output"
    return 0
}

_cycle_apply_feedback() {
    local iter_next="$1" state_dir="$2"
    local fb_dir="$state_dir/cycle-${_CYCLE_TRAP_CYCLE_ID}/iter-${iter_next}/feedback"
    mkdir -p "$fb_dir" 2>/dev/null || true
    export ZBUILD_CYCLE_FEEDBACK_DIR="$fb_dir"
    [[ ${#_CYCLE_FEEDBACK[@]} -eq 0 ]] && return 0

    local rec
    for rec in "${_CYCLE_FEEDBACK[@]}"; do
        # "from_stage:from_output|to_stage:to_field:required"
        local from_part="${rec%%|*}"
        local to_part="${rec#*|}"
        local from_stage="${from_part%%:*}"
        local from_output="${from_part#*:}"
        local to_stage="${to_part%%:*}"
        local rest="${to_part#*:}"
        local to_field="${rest%%:*}"
        local required="${rest#*:}"
        local src
        src="$(_cycle_resolve_from_path "$state_dir" "$from_stage" "$from_output")"
        local dst="$fb_dir/${to_field}.txt"
        if [[ ! -e "$src" ]]; then
            _cycle_emit "cycle.feedback.missing" \
                "iter_next=$iter_next" "from_stage=$from_stage" \
                "from_output=$from_output" "to_stage=$to_stage" \
                "to_field=$to_field" "required=$required" \
                "src=$src"
            # required=true → fail-closed; abort by signalling rc!=0
            if [[ "$required" == "true" ]]; then
                return 1
            fi
            continue
        fi
        if ! cp "$src" "$dst" 2>/dev/null; then
            _cycle_emit "cycle.feedback.missing" \
                "iter_next=$iter_next" "from_stage=$from_stage" \
                "to_field=$to_field" "reason=copy_failed"
            return 1
        fi
    done
    # #511 Pin 9: atomic `.complete` sentinel — written AFTER all feedback
    # files are copied. On resume entry to iter N+1, missing `.complete`
    # signals "re-run _cycle_apply_feedback" (kill between mkdir and cp left
    # partial dir, mitigating silent-failure finding #9).
    : > "$fb_dir/.complete" 2>/dev/null || true
    return 0
}

# ─── _cycle_state_init <state_file> ──────────────────────────────────────────
# Schema-additive: ensure .cycle_iterations[<cycle_id>] exists. Defensive init
# guards against older state files crashing on `.cycle_iterations` access
# (silent-failure finding #7).
_cycle_state_jq_init() {
    jq --arg id "$_ZB_CYCLE_ID" \
       --arg history "$_ZB_CYCLE_HISTORY" \
       --argjson max "$_ZB_CYCLE_MAX" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '(.cycle_iterations //= {})
        | (.cycle_iterations[$id] //= {
            status: "in_progress",
            current_iter: 0,
            max_iterations: $max,
            history_file: $history,
            iter: []
          })
        | .updated_at = $now'
}

_cycle_state_init() {
    local state_file="$1" cycle_id="$2" history_file="$3" max_iter="$4"
    export _ZB_CYCLE_ID="$cycle_id" _ZB_CYCLE_HISTORY="$history_file" \
           _ZB_CYCLE_MAX="$max_iter"
    locked_state_update "$state_file" "_cycle_state_jq_init" || return 1
    unset _ZB_CYCLE_ID _ZB_CYCLE_HISTORY _ZB_CYCLE_MAX
}

# ─── _cycle_state_write_iter_atomic ──────────────────────────────────────────
# Single atomic write per iter boundary (silent-failure finding #12).
# Updates: current_iter, iter[] append, status. NEVER split.
_cycle_state_jq_write_iter() {
    jq --arg id "$_ZB_CYCLE_ID" \
       --argjson n "$_ZB_CYCLE_N" \
       --arg verdict "$_ZB_CYCLE_VERDICT" \
       --arg status "$_ZB_CYCLE_ITER_STATUS" \
       --argjson fc "$_ZB_CYCLE_FC" \
       --arg overall "$_ZB_CYCLE_OVERALL" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '(.cycle_iterations //= {})
        | (.cycle_iterations[$id] //= {iter:[]})
        | .cycle_iterations[$id].current_iter = $n
        | .cycle_iterations[$id].status = $overall
        | .cycle_iterations[$id].iter += [{
              n: $n,
              status: $status,
              verdict: $verdict,
              failure_count: $fc,
              ended_at: $now
          }]
        | .updated_at = $now'
}

_cycle_state_write_iter_atomic() {
    local state_file="$1" cycle_id="$2" n="$3" verdict="$4" iter_status="$5" \
          failure_count="$6" overall_status="$7"
    export _ZB_CYCLE_ID="$cycle_id" _ZB_CYCLE_N="$n" \
           _ZB_CYCLE_VERDICT="$verdict" _ZB_CYCLE_ITER_STATUS="$iter_status" \
           _ZB_CYCLE_FC="$failure_count" _ZB_CYCLE_OVERALL="$overall_status"
    locked_state_update "$state_file" "_cycle_state_jq_write_iter" || return 1
    unset _ZB_CYCLE_ID _ZB_CYCLE_N _ZB_CYCLE_VERDICT _ZB_CYCLE_ITER_STATUS \
          _ZB_CYCLE_FC _ZB_CYCLE_OVERALL
}

# ─── _cycle_iter_dispatch <iter> <state_file> ────────────────────────────────
# Dispatches each stage in _CYCLE_STAGES[] via the runner's existing per-stage
# dispatch helper. F1 ships a HOOK-BASED stub: if the function
# `cycle_dispatch_stage` is declared (test harness OR runner), call it; else
# emit cycle.config.invalid and fail. Returns aggregate failure_count.
# Sets globals: _CYCLE_LAST_VERDICTS_BLOB (JSON), _CYCLE_LAST_FAILURE_COUNT.
# ─── _cycle_pre_iter_cleanup (#511 Pin 8) ────────────────────────────────────
# Before EACH cycle iter dispatch, delete per-cycle-stage primary outputs so a
# stale prior-iter artifact cannot silently satisfy `until: verdict==pass`
# (silent-failure finding #2). Reads each stage's manifest primary-output path.
_cycle_pre_iter_cleanup() {
    local iter="$1" state_dir="$2"
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_CYCLE_ORCH_ROOT/plugins}"
    declare -F manifest_graph_collect >/dev/null 2>&1 || return 0
    declare -F manifest_graph_primary_output >/dev/null 2>&1 || return 0
    local s
    for s in "${_CYCLE_STAGES[@]}"; do
        local manifest
        manifest="$(manifest_graph_collect "$plugins_root" "$s" 2>/dev/null || true)"
        [[ -z "$manifest" || ! -f "$manifest" ]] && continue
        local row
        row="$(manifest_graph_primary_output "$manifest" 2>/dev/null || true)"
        [[ -z "$row" ]] && continue
        # row: id|type||required|path
        local p="${row##*|}"
        [[ -z "$p" ]] && continue
        local resolved="$p"
        resolved="${resolved//\$\{artifact_dir\}/$state_dir/artifacts}"
        resolved="${resolved//\$\{state_dir\}/$state_dir}"
        if [[ -f "$resolved" ]]; then
            rm -f "$resolved" 2>/dev/null || true
            _cycle_emit "cycle.artifacts.cleared" "iter=$iter" "stage=$s" \
                "path=$resolved"
        fi
    done
    return 0
}

_cycle_iter_dispatch() {
    local iter="$1" state_file="$2"
    _CYCLE_LAST_VERDICTS_BLOB="{}"
    _CYCLE_LAST_FAILURE_COUNT=0

    if ! declare -F cycle_dispatch_stage >/dev/null 2>&1; then
        error "cycle_orchestrator: no cycle_dispatch_stage hook registered (F2 wires this)"
        _cycle_emit "cycle.config.invalid" "iter=$iter" \
            "reason=no_dispatch_hook"
        return 1
    fi

    # #511 Pin 8: per-iter cleanup BEFORE dispatch.
    local _state_dir; _state_dir="$(dirname "$state_file")"
    _cycle_pre_iter_cleanup "$iter" "$_state_dir"

    local s rc verdict status
    local blob="{}"
    local fail=0
    # Capture caller's errexit state — we MUST NOT alter it after returning
    # (silent-failure: leaking `set -e` ON breaks set-e-naive callers).
    local _had_e=0; case $- in *e*) _had_e=1 ;; esac
    # #566: snapshot caller's ZBUILD_CURRENT_STAGE so we can restore it after
    # the dispatch loop (mirrors the linear-stage path at runner.sh:1057-1059).
    # Without this export, route.sh:679's _iter_stage_id resolves to "" and the
    # per-iteration [llm] banner is silently skipped for every stage in a cycle.
    local _prior_stage_set=0 _prior_stage=""
    if [[ -n "${ZBUILD_CURRENT_STAGE+x}" ]]; then
        _prior_stage_set=1
        _prior_stage="$ZBUILD_CURRENT_STAGE"
    fi
    # #682 (Wave 15-D): track 1-based position within _CYCLE_STAGES[] so each
    # member dispatch publishes a hierarchical `<iter>.<position>` seq label
    # via ZBUILD_STAGE_IO_SEQ_LABEL. The stage-io banner picks this up and
    # renders e.g. `seq=1.2` instead of the per-stage cardinal. Empty label
    # means cardinal fallback (back-compat).
    local _cyc_pos=0
    # ADR-027 (Wave 17-B #703): cycle-as-member support. For each cycle
    # member, check `_TPL_STAGE_TYPE_<member>` — if it's `cycle`, recurse
    # into cycle_orchestrator_run for that nested cycle and map its terminal
    # rc onto the verdict blob (converged→pass, others→fail). rc=6 (the new
    # cycle_abort class) propagates outward unchanged.
    for s in "${_CYCLE_STAGES[@]}"; do
        # ADR-025 (Wave 15-B #684) pre-flight: the sentinel may have been
        # armed by the runner's SIGINT trap between this stage and the last.
        # Bail before spawning the next child so the abort observes at the
        # earliest possible dispatch boundary. THIS is the dogfood-bug fix:
        # Wave 15 dogfood saw rc=130 swallowed because the previous shape
        # treated every non-zero rc as a generic stage failure (fail++) and
        # kept iterating after Ctrl-C.
        if ! _zbuild_check_abort; then
            [[ $_had_e -eq 1 ]] && set -e
            return 130
        fi
        _cyc_pos=$(( _cyc_pos + 1 ))
        export ZBUILD_CYCLE_ITER="$iter"
        export ZBUILD_CYCLE_ID="${_CYCLE_TRAP_CYCLE_ID}"
        # Wave 19-B (#718): N-level recursive seq label via prefix accumulation.
        # Each cycle entry appends `.<iter>.<position>` to the inherited prefix
        # in ZBUILD_SEQ_PREFIX. Bottoms out at any depth — single-cycle templates
        # get 3-segment labels (prefix=cardinal, e.g. "3.1.1"), nested cycles get
        # 5/7/... segments (prefix="3.1.1" for the inner cycle's children, so
        # build = "3.1.1.1.1"). Back-compat path: when ZBUILD_SEQ_PREFIX is
        # unset (orchestrator invoked standalone in a unit/integration test),
        # the label is the 2-level "<iter>.<position>".
        local _member_label
        if [[ -n "${ZBUILD_SEQ_PREFIX:-}" ]]; then
            _member_label="${ZBUILD_SEQ_PREFIX}.${iter}.${_cyc_pos}"
        else
            _member_label="${iter}.${_cyc_pos}"
        fi
        export ZBUILD_STAGE_IO_SEQ_LABEL="$_member_label"
        # #682: 1 blank line BEFORE every member-stage banner (within-iter gap).
        # Mirrors Wave 11B's linear-runner blank line — keeps consecutive stage
        # banners from rendering flush. Best-effort; never aborts on bad fd.
        printf '\n' >&2 2>/dev/null || true
        # #566: stage identity must propagate to subshells so router/stage-io,
        # per-stage timeouts, redaction scope, and cost-ledger events all
        # resolve `${ZBUILD_CURRENT_STAGE}` correctly inside cycles.
        export ZBUILD_CURRENT_STAGE="$s"
        # Re-install traps — silent-failure finding #6: nested route loops
        # clobber INT/TERM. Reassert ownership after each stage.
        _cycle_install_traps
        # ADR-027: cycle-as-member branch. Check the stage type discriminator
        # the loader set. If this member is itself a cycle, recurse into the
        # orchestrator with its own state — recursion depth is bounded by
        # max_iterations at each level + the load-time acyclicity check in
        # _tpl_validate_flow_acyclic. Otherwise fall through to leaf dispatch.
        local _member_type_var="_TPL_STAGE_TYPE_${s//-/_}"
        local _member_type="${!_member_type_var:-leaf}"
        if [[ "$_member_type" == "cycle" ]]; then
            set +e
            # Wave 19-B (#718): set ZBUILD_SEQ_PREFIX to this member's label so
            # the nested cycle's children inherit the full path
            # ("<outer_prefix>.<outer_iter>.<outer_pos>"). Save the prior prefix
            # and restore it on return so sibling members of THIS cycle keep
            # using the outer prefix.
            local _prior_seq_prefix_set=0 _prior_seq_prefix=""
            if [[ -n "${ZBUILD_SEQ_PREFIX+x}" ]]; then
                _prior_seq_prefix_set=1
                _prior_seq_prefix="$ZBUILD_SEQ_PREFIX"
            fi
            export ZBUILD_SEQ_PREFIX="$_member_label"
            # Save outer cycle's state — recursion clobbers _CYCLE_* globals.
            # ADR-026 / Wave 18-B (#707): also save _CYCLE_FEEDBACK (and the
            # outer cycle's exit_when/abort_when arrays implicitly via
            # _CYCLE_TRAP_CYCLE_ID, which _cycle_apply_feedback uses to
            # rebuild the iter-next feedback dir path). Without restoring
            # _CYCLE_FEEDBACK, the outer cycle's post-iter _cycle_apply_feedback
            # would use the INNER cycle's feedback edges (e.g. inner
            # build_test_cycle's prior_test_assessment) instead of the outer
            # review_cycle's review→build prior_review_feedback edge, silently
            # dropping the ADR-026 wiring.
            local _outer_cid="$_CYCLE_TRAP_CYCLE_ID"
            local _outer_iter="$_CYCLE_TRAP_ITER"
            local _outer_max="$_CYCLE_MAX_ITER"
            local _outer_on_max="$_CYCLE_ON_MAX"
            local _outer_until_stage="$_CYCLE_UNTIL_STAGE"
            local _outer_until_field="$_CYCLE_UNTIL_FIELD"
            local _outer_until_op="$_CYCLE_UNTIL_OP"
            local _outer_until_value="$_CYCLE_UNTIL_VALUE"
            local -a _outer_feedback=( "${_CYCLE_FEEDBACK[@]}" )
            local -a _outer_stages=( "${_CYCLE_STAGES[@]}" )
            cycle_orchestrator_run "$s" "$state_dir" "$state_file"
            rc=$?
            # Wave 19-B (#718): restore prior seq prefix BEFORE any return path
            # (verdict normal, rc=6, rc=130, rc=143). Prefix must not leak to
            # sibling members of THIS cycle or to callers above.
            if [[ $_prior_seq_prefix_set -eq 1 ]]; then
                export ZBUILD_SEQ_PREFIX="$_prior_seq_prefix"
            else
                unset ZBUILD_SEQ_PREFIX
            fi
            # Restore outer state for verdict bookkeeping, exit/abort
            # predicate evaluation, AND outer feedback wiring (so the
            # outer's _cycle_apply_feedback at iter end sees its own edges,
            # not the inner cycle's, and _cycle_check_until evaluates the
            # OUTER's exit_when stage/field/op/value, not the inner's
            # clobbered residue).
            _CYCLE_TRAP_CYCLE_ID="$_outer_cid"
            _CYCLE_TRAP_ITER="$_outer_iter"
            _CYCLE_MAX_ITER="$_outer_max"
            _CYCLE_ON_MAX="$_outer_on_max"
            _CYCLE_UNTIL_STAGE="$_outer_until_stage"
            _CYCLE_UNTIL_FIELD="$_outer_until_field"
            _CYCLE_UNTIL_OP="$_outer_until_op"
            _CYCLE_UNTIL_VALUE="$_outer_until_value"
            _CYCLE_FEEDBACK=( "${_outer_feedback[@]}" )
            _CYCLE_STAGES=( "${_outer_stages[@]}" )
            [[ $_had_e -eq 1 ]] && set -e
            # Map nested-cycle terminal rc → outer verdict/status.
            case "$rc" in
                0) _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete" ;;
                6) # cycle_abort propagates outward immediately.
                   _CYCLE_LAST_TERMINATED_REASON="cycle_abort"
                   _cycle_clear_traps
                   return 6 ;;
                130|143) _cycle_clear_traps; return "$rc" ;;
                *) _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_STATUS="failed" ;;
            esac
            verdict="$_CYCLE_DISPATCH_VERDICT"
            status="$_CYCLE_DISPATCH_STATUS"
            blob="$(jq -c --arg s "$s" --arg v "$verdict" --arg st "$status" \
                '. + {($s): {verdict:$v, status:$st}}' <<< "$blob" 2>/dev/null)" || blob="{}"
            if [[ $rc -ne 0 ]]; then
                fail=$(( fail + 1 ))
            fi
            continue
        fi
        set +e
        cycle_dispatch_stage "$s" "$iter" "$state_file"
        rc=$?
        # Restore caller's errexit if they had it on
        [[ $_had_e -eq 1 ]] && set -e
        # ADR-025 (Wave 15-B #684) post-flight: rc=130 from the child means
        # SIGINT propagated up through the dispatch chain. Surface 130 from
        # this iter so the outer for-iter loop returns 130 to the runner,
        # which already maps rc=130 → pipeline.aborted reason=sigint.
        # Copilot P1 on #693: use the ADR-025-recommended `|| return $?`
        # form. `_zbuild_propagate_abort "$rc"` as a bare command after
        # the `set -e` restore above could terminate the function
        # immediately under errexit before any explicit `return` ran.
        # The `||` form inhibits errexit for the call and lets the
        # explicit `return $?` carry the abort rc cleanly.
        _zbuild_propagate_abort "$rc" || return $?
        verdict="${_CYCLE_DISPATCH_VERDICT:-}"
        status="${_CYCLE_DISPATCH_STATUS:-}"
        if [[ -z "$verdict" ]]; then
            verdict="missing"
        fi
        if [[ -z "$status" ]]; then
            status="missing"
        fi
        blob="$(jq -c --arg s "$s" --arg v "$verdict" --arg st "$status" \
            '. + {($s): {verdict:$v, status:$st}}' <<< "$blob" 2>/dev/null)" || blob="{}"
        if [[ $rc -ne 0 ]]; then
            fail=$(( fail + 1 ))
        fi
    done
    unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_ID ZBUILD_STAGE_IO_SEQ_LABEL
    # #566: restore caller's ZBUILD_CURRENT_STAGE — preserves prior value if
    # set, or unsets (we own the var only within this loop).
    if [[ $_prior_stage_set -eq 1 ]]; then
        export ZBUILD_CURRENT_STAGE="$_prior_stage"
    else
        unset ZBUILD_CURRENT_STAGE
    fi
    _CYCLE_LAST_VERDICTS_BLOB="$blob"
    _CYCLE_LAST_FAILURE_COUNT="$fail"
    # #511 Pin 10: failure_count fidelity. The orchestrator's default is the
    # count of stages with rc!=0 (always 0..|stages|). For the build/test
    # cycle that under-reports actual progress — a test run that drops from
    # 17 failing tests to 3 looks identical (fc=1 either way), masking
    # convergence and starving the divergence detector. If a `test` stage
    # ran in this iter AND test-results.json declares `.failed`, prefer that
    # integer (silent-failure finding #11).
    local _has_test=0 _ts
    for _ts in "${_CYCLE_STAGES[@]}"; do
        [[ "$_ts" == "test" ]] && _has_test=1 && break
    done
    if [[ $_has_test -eq 1 ]]; then
        local _tr="$_state_dir/artifacts/test-results.json"
        if [[ -s "$_tr" ]]; then
            local _failed_n
            _failed_n="$(jq -r '.failed // 0' "$_tr" 2>/dev/null || echo 0)"
            if [[ "$_failed_n" =~ ^[0-9]+$ ]]; then
                _CYCLE_LAST_FAILURE_COUNT="$_failed_n"
            fi
        fi
    fi
    return 0
}

# ─── _cycle_handle_terminal_rc — runner-facing helper ────────────────────────
# Maps orchestrator rc → reason → (a) cycle.complete event (durable, fd-event)
# and (b) operator-fd-2 exit banner via registered `cycle_exit_hook`.
# Silent-failure mitigation #8: this is the SINGLE choke point for cycle exit
# banner emission. All inline `cycle.complete` emit sites (max_iterations,
# plateau, divergence, aborted) route through here OR explicitly invoke the
# hook themselves; the runner calls it once after cycle_orchestrator_run as a
# backstop for paths the orchestrator didn't already cover (defensive — the
# event is idempotent at this layer since it carries reason; duplicate fd-2
# banners are guarded via _CYCLE_EXIT_BANNER_EMITTED).
_CYCLE_EXIT_BANNER_EMITTED=0
_cycle_handle_terminal_rc() {
    local rc="$1" cycle_id="$2" state_file="$3"
    local reason
    case "$rc" in
        0)   reason="converged" ;;
        1)   reason="max_iterations" ;;
        2)   reason="plateau" ;;
        3)   reason="divergence" ;;
        4)   reason="${_CYCLE_LAST_TERMINATED_REASON:-config_invalid}" ;;
        5)   reason="blocked" ;;
        6)   reason="cycle_abort" ;;
        130) reason="aborted" ;;
        *)   reason="error" ;;
    esac
    eb_emit_event "cycle.complete" \
        "cycle_id=$cycle_id" "iter=${_CYCLE_LAST_ITERATIONS}" \
        "reason=$reason" 2>/dev/null || true
    # Exit banner via registered hook — event emitted FIRST (durable above),
    # banner SECOND (best-effort). Idempotency guard: emit at most once per
    # cycle_orchestrator_run terminal-rc fan-in. Reset by the next cycle
    # entry hook invocation.
    if [[ "${_CYCLE_EXIT_BANNER_EMITTED:-0}" != "1" ]]; then
        if declare -F cycle_exit_hook >/dev/null 2>&1; then
            cycle_exit_hook "$cycle_id" "$reason" \
                "${_CYCLE_LAST_ITERATIONS:-0}" "${_CYCLE_MAX_ITER:-0}" || true
        fi
        _CYCLE_EXIT_BANNER_EMITTED=1
    fi
}

# ─── cycle_orchestrator_run <cycle_id> <state_dir> <state_file> ──────────────
cycle_orchestrator_run() {
    local cycle_id="$1" state_dir="$2" state_file="$3"
    # Capture caller's errexit FIRST — orchestrator runs with set +e internally
    # so a stage failure doesn't yank the rug out from a set-e-active caller.
    # Restored before every return path via the { ...; return N; } idiom.
    local _ORCH_HAD_E=0; case $- in *e*) _ORCH_HAD_E=1 ;; esac
    set +e
    if [[ -z "$cycle_id" || -z "$state_dir" || -z "$state_file" ]]; then
        error "cycle_orchestrator_run: cycle_id, state_dir, state_file required"
        { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
    fi

    _CYCLE_TRAP_CYCLE_ID="$cycle_id"
    _CYCLE_TRAP_ITER=0
    _CYCLE_LAST_TERMINATED_REASON=""
    _CYCLE_LAST_ITERATIONS=0
    # #524: reset exit-banner idempotency flag for this cycle run.
    _CYCLE_EXIT_BANNER_EMITTED=0
    _CYCLE_ITER_START_MS=()

    if ! _cycle_load_template "$cycle_id"; then
        _CYCLE_LAST_TERMINATED_REASON="config_invalid"
        { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
    fi

    local history_file="$state_dir/cycle-${cycle_id}-history.jsonl"
    _CYCLE_LAST_HISTORY_FILE="$history_file"
    _CYCLE_TRAP_HISTORY_FILE="$history_file"
    : > "$history_file" 2>/dev/null || true

    _cycle_state_init "$state_file" "$cycle_id" "$history_file" "$_CYCLE_MAX_ITER" || {
        error "cycle_orchestrator_run: state init failed for $cycle_id"
        { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
    }

    _cycle_install_traps

    eb_emit_event "cycle.start" \
        "cycle_id=$cycle_id" "iter=1" \
        "max=$_CYCLE_MAX_ITER" \
        "stages=${_CYCLE_STAGES[*]}" 2>/dev/null || true

    local iter
    for (( iter=1; iter <= _CYCLE_MAX_ITER; iter++ )); do
        _CYCLE_TRAP_ITER="$iter"
        _CYCLE_LAST_ITERATIONS="$iter"

        # #682: 2 blank lines BEFORE each iter separator (inter-iter gap),
        # except before the very first iter where 1 blank is enough — the
        # divider function already prints its own leading `\n`, so emit ONE
        # extra blank here for iter>=2 (giving the operator a clear visual
        # break between iters distinct from within-iter stage gaps).
        if [[ "$iter" -ge 2 ]]; then
            printf '\n' >&2 2>/dev/null || true
        fi
        # #524 iter-begin hook — operator-visible iter divider. Runner registers
        # `cycle_iter_begin_hook` to call _render_cycle_iter_divider. Best-effort
        # (never aborts cycle on hook failure). Records wall clock for elapsed.
        if declare -F cycle_iter_begin_hook >/dev/null 2>&1; then
            # Don't redirect stderr here — the hook's renderer writes to fd 2
            # by design (operator chrome). Helper-internal redirects already
            # handle broken-fd tolerance. `|| true` keeps a hook failure from
            # aborting the cycle.
            cycle_iter_begin_hook "$cycle_id" "$iter" "$_CYCLE_MAX_ITER" || true
        fi

        # ADR-025 (Wave 15-B #684) pre-flight: check the sentinel before
        # starting each new cycle iteration so a SIGINT between iterations
        # is honored at the iter boundary (not buried until the next stage
        # boundary inside _cycle_iter_dispatch).
        if ! _zbuild_check_abort; then
            _CYCLE_LAST_TERMINATED_REASON="aborted"
            _cycle_clear_traps
            { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 130; }
        fi

        # Dispatch the cycle's stages in order.
        set +e
        _cycle_iter_dispatch "$iter" "$state_file"
        local _iter_rc=$?
        [[ $_ORCH_HAD_E -eq 1 ]] && set -e
        # ADR-025 (Wave 15-B #684): rc=130 from the per-iter dispatch is the
        # abort signal — surface it distinctly from the generic error path
        # (rc=4 / config_invalid) so the runner can map it to
        # pipeline.aborted reason=sigint. Without this branch, the old
        # `if ! _cycle_iter_dispatch` shape collapses 130 into 4.
        if [[ $_iter_rc -eq 130 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="aborted"
            _cycle_clear_traps
            return 130
        fi
        if [[ $_iter_rc -ne 0 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="error"
            _cycle_clear_traps
            return 4
        fi
        # Re-install (defensive — _cycle_iter_dispatch re-installs inside the
        # per-stage loop but a stage might have left them cleared on the path
        # out).
        _cycle_install_traps

        local verdicts_blob="$_CYCLE_LAST_VERDICTS_BLOB"
        local failure_count="$_CYCLE_LAST_FAILURE_COUNT"
        # Pull verdict/status of the until-stage for the history row.
        local h_verdict h_status
        h_verdict="$(jq -r --arg s "$_CYCLE_UNTIL_STAGE" \
            '.[$s].verdict // "missing"' <<< "$verdicts_blob" 2>/dev/null)"
        h_status="$(jq -r --arg s "$_CYCLE_UNTIL_STAGE" \
            '.[$s].status // "missing"' <<< "$verdicts_blob" 2>/dev/null)"

        # Termination evaluation (priority order — see ADR-021):
        #   1) until satisfied (converged)
        #   2) max_iterations
        #   3) plateau (iter ≥ 2)
        #   4) divergence (iter ≥ K+1)
        local converged=1
        local _ce=0; case $- in *e*) _ce=1 ;; esac
        set +e; _cycle_check_until "$verdicts_blob"; converged=$?
        [[ $_ce -eq 1 ]] && set -e

        # Record the history row FIRST — termination checks need durable data.
        _cycle_record_iter_outcome "$history_file" "$iter" \
            "$h_verdict" "$h_status" "$failure_count" || true

        # ADR-027 (Wave 17-B #703): abort_when predicate. If matched, the
        # cycle returns rc=6 (cycle_abort) which propagates through every
        # enclosing cycle to the runner via _zbuild_propagate_abort. Evaluated
        # AFTER exit_when so converged-via-exit_when takes priority on tie.
        local abort_matched=1
        local _aw_stage_var="_TPL_CYCLE_ABORT_WHEN_STAGE_${cycle_id//-/_}"
        if [[ -n "${!_aw_stage_var:-}" ]]; then
            _cycle_check_abort_when "$verdicts_blob"; abort_matched=$?
        fi

        # Decide overall status for the SINGLE atomic write (ADR-021: never
        # split state writes within an iter boundary).
        local overall_status="in_progress"
        local term_rc=-1
        if [[ "$converged" -eq 0 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="converged"
            overall_status="complete"; term_rc=0
        elif [[ "$abort_matched" -eq 0 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="cycle_abort"
            overall_status="cycle_abort"; term_rc=6
        elif _cycle_check_max_iterations "$iter" "$_CYCLE_MAX_ITER"; then
            _CYCLE_LAST_TERMINATED_REASON="max_iterations"
            overall_status="max_iterations"; term_rc=1
        elif _cycle_detect_plateau "$history_file" "$_CYCLE_PLATEAU_WINDOW"; then
            _CYCLE_LAST_TERMINATED_REASON="plateau"
            overall_status="plateau"; term_rc=2
        elif _cycle_detect_divergence "$history_file" "$_CYCLE_DIVERGENCE_WINDOW"; then
            _CYCLE_LAST_TERMINATED_REASON="divergence"
            overall_status="divergence"; term_rc=3
        elif _cycle_detect_blocked "$verdicts_blob" "$iter"; then
            # #528: structural cannot-progress class — fires LAST (after
            # divergence) so legitimate "make progress" predicates take
            # priority. rc=5 halts the pipeline (runner.sh:618).
            _CYCLE_LAST_TERMINATED_REASON="blocked"
            overall_status="blocked"; term_rc=5
        fi

        # Single atomic state write per iter boundary.
        _cycle_state_write_iter_atomic "$state_file" "$cycle_id" "$iter" \
            "$h_verdict" "$h_status" "$failure_count" "$overall_status" || true

        eb_emit_event "cycle.iteration.complete" \
            "cycle_id=$cycle_id" "iter=$iter" "verdict=$h_verdict" \
            "velocity=$(( 0 - failure_count ))" \
            "failure_count=$failure_count" 2>/dev/null || true

        # #524 iter-complete hook — operator-visible iter trailer. Event emit
        # is durable above; the hook is best-effort (silent-failure mitigation
        # #1: event FIRST, banner SECOND). Runner registers this to call
        # _render_cycle_iter_complete with verdict / velocity / fc / elapsed.
        if declare -F cycle_iter_complete_hook >/dev/null 2>&1; then
            cycle_iter_complete_hook "$cycle_id" "$iter" "$h_verdict" \
                "$(( 0 - failure_count ))" "$failure_count" || true
        fi

        if [[ $term_rc -ge 0 ]]; then
            # #524 Pin 8: route ALL terminal-rc paths through
            # _cycle_handle_terminal_rc — single fan-in for cycle.complete
            # event + operator exit banner. Diagnostic events (cycle.plateau /
            # cycle.divergence) stay inline since they carry termination-
            # specific evidence the central helper doesn't know about.
            case "$term_rc" in
                2) eb_emit_event "cycle.plateau" "cycle_id=$cycle_id" "iter=$iter" "evidence=verdict_tuple_identical" "streak=$_CYCLE_PLATEAU_WINDOW" 2>/dev/null || true ;;
                3) eb_emit_event "cycle.divergence" "cycle_id=$cycle_id" "iter=$iter" "velocity_history=$failure_count" 2>/dev/null || true ;;
                5) # #528: emit cycle.blocked between cycle.iteration.complete
                   # (already emitted above) and cycle.complete reason=blocked
                   # — strict event ordering per MED #9. cycle.complete itself
                   # is emitted by _cycle_handle_terminal_rc below (#524 fan-in).
                   eb_emit_event "cycle.blocked" "cycle_id=$cycle_id" "iter=$iter" \
                       "stage=${_CYCLE_BLOCKED_STAGE:-unknown}" \
                       "verdict=${_CYCLE_BLOCKED_VERDICT:-unknown}" \
                       "feedback_missing=false" 2>/dev/null || true ;;
            esac
            _cycle_handle_terminal_rc "$term_rc" "$cycle_id" "$state_file"
            _cycle_clear_traps
            { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return "$term_rc"; }
        fi

        # Not terminating — wire feedback for next iter.
        if ! _cycle_apply_feedback "$(( iter + 1 ))" "$state_dir"; then
            _CYCLE_LAST_TERMINATED_REASON="aborted"
            _cycle_state_write_iter_atomic "$state_file" "$cycle_id" "$iter" \
                "$h_verdict" "$h_status" "$failure_count" "aborted" || true
            # #524 Pin 8: route through central helper (emits cycle.complete
            # + exit banner). rc=130 → reason=aborted in handler map.
            _cycle_handle_terminal_rc 130 "$cycle_id" "$state_file"
            _cycle_clear_traps
            { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
        fi
    done

    # Loop fell through without hitting max_iterations in the body — defensive
    _CYCLE_LAST_TERMINATED_REASON="max_iterations"
    _cycle_clear_traps
    { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 1; }
}
