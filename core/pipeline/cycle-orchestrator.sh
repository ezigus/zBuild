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
# shellcheck source=../state/atomic.sh
source "$_CYCLE_ORCH_ROOT/core/state/atomic.sh"
# shellcheck source=../state/resume.sh
source "$_CYCLE_ORCH_ROOT/core/state/resume.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_CYCLE_ORCH_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=./template.sh
source "$_CYCLE_ORCH_ROOT/core/pipeline/template.sh"

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

# ─── _cycle_emit — wrapper around eb_emit_event with cycle envelope ──────────
# Adds cycle_id automatically; payload is flat k=v per zbuild convention.
_cycle_emit() {
    local type="$1"; shift
    eb_emit_event "$type" "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" "$@" \
        2>/dev/null || true
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
        eb_emit_event "cycle.config.invalid" \
            "cycle_id=$cycle_id" "reason=no_stages" 2>/dev/null || true
        return 4
    fi
    local IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    _CYCLE_STAGES=($stages_csv)
    IFS="$IFS_save"

    _CYCLE_MAX_ITER="${!max_var:-}"
    if [[ -z "$_CYCLE_MAX_ITER" ]] || ! [[ "$_CYCLE_MAX_ITER" =~ ^[0-9]+$ ]]; then
        error "cycle '$cycle_id': max_iterations required (integer 1..${_CYCLE_ABSOLUTE_MAX})"
        eb_emit_event "cycle.config.invalid" \
            "cycle_id=$cycle_id" "reason=max_iterations_missing_or_nonint" \
            "value=${_CYCLE_MAX_ITER:-<unset>}" 2>/dev/null || true
        return 4
    fi
    if [[ "$_CYCLE_MAX_ITER" -lt 1 || "$_CYCLE_MAX_ITER" -gt "$_CYCLE_ABSOLUTE_MAX" ]]; then
        error "cycle '$cycle_id': max_iterations must be 1..${_CYCLE_ABSOLUTE_MAX}, got: $_CYCLE_MAX_ITER"
        eb_emit_event "cycle.config.invalid" \
            "cycle_id=$cycle_id" "reason=max_iterations_out_of_range" \
            "value=$_CYCLE_MAX_ITER" "absolute_max=$_CYCLE_ABSOLUTE_MAX" \
            2>/dev/null || true
        return 4
    fi

    _CYCLE_ON_MAX="${!on_max_var:-continue}"
    if [[ "$_CYCLE_ON_MAX" != "continue" && "$_CYCLE_ON_MAX" != "halt" ]]; then
        error "cycle '$cycle_id': on_max must be continue|halt, got: $_CYCLE_ON_MAX"
        eb_emit_event "cycle.config.invalid" \
            "cycle_id=$cycle_id" "reason=on_max_invalid" \
            "value=$_CYCLE_ON_MAX" 2>/dev/null || true
        return 4
    fi

    _CYCLE_UNTIL_STAGE="${!us_var:-}"
    _CYCLE_UNTIL_FIELD="${!uf_var:-}"
    _CYCLE_UNTIL_OP="${!uo_var:-}"
    _CYCLE_UNTIL_VALUE="${!uv_var:-}"

    if [[ -z "$_CYCLE_UNTIL_STAGE" || -z "$_CYCLE_UNTIL_FIELD" \
          || -z "$_CYCLE_UNTIL_OP" || -z "$_CYCLE_UNTIL_VALUE" ]]; then
        error "cycle '$cycle_id': until.{stage,field,op,value} all required"
        eb_emit_event "cycle.config.invalid" \
            "cycle_id=$cycle_id" "reason=until_incomplete" 2>/dev/null || true
        return 4
    fi
    # v1 whitelist
    case "$_CYCLE_UNTIL_FIELD" in
        verdict|status) ;;
        *)
            error "cycle '$cycle_id': until.field must be verdict|status, got: $_CYCLE_UNTIL_FIELD"
            eb_emit_event "cycle.config.invalid" \
                "cycle_id=$cycle_id" "reason=until_field_invalid" \
                "value=$_CYCLE_UNTIL_FIELD" 2>/dev/null || true
            return 4
            ;;
    esac
    case "$_CYCLE_UNTIL_OP" in
        eq|ne) ;;
        *)
            error "cycle '$cycle_id': until.op must be eq|ne, got: $_CYCLE_UNTIL_OP"
            eb_emit_event "cycle.config.invalid" \
                "cycle_id=$cycle_id" "reason=until_op_invalid" \
                "value=$_CYCLE_UNTIL_OP" 2>/dev/null || true
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
        eb_emit_event "cycle.config.invalid" \
            "cycle_id=$cycle_id" "reason=until_stage_outside_cycle" \
            "value=$_CYCLE_UNTIL_STAGE" 2>/dev/null || true
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
        local src="$state_dir/artifacts/${from_stage}/${from_output}"
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

    local s rc verdict status
    local blob="{}"
    local fail=0
    # Capture caller's errexit state — we MUST NOT alter it after returning
    # (silent-failure: leaking `set -e` ON breaks set-e-naive callers).
    local _had_e=0; case $- in *e*) _had_e=1 ;; esac
    for s in "${_CYCLE_STAGES[@]}"; do
        export ZBUILD_CYCLE_ITER="$iter"
        export ZBUILD_CYCLE_ID="${_CYCLE_TRAP_CYCLE_ID}"
        # Re-install traps — silent-failure finding #6: nested route loops
        # clobber INT/TERM. Reassert ownership after each stage.
        _cycle_install_traps
        set +e
        cycle_dispatch_stage "$s" "$iter" "$state_file"
        rc=$?
        # Restore caller's errexit if they had it on
        [[ $_had_e -eq 1 ]] && set -e
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
    unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_ID
    _CYCLE_LAST_VERDICTS_BLOB="$blob"
    _CYCLE_LAST_FAILURE_COUNT="$fail"
    return 0
}

# ─── _cycle_handle_terminal_rc — runner-facing helper ────────────────────────
# Maps orchestrator rc → pipeline-state status. Callers (runner) decide whether
# to halt the linear pipeline based on rc + on_max policy.
_cycle_handle_terminal_rc() {
    local rc="$1" cycle_id="$2" state_file="$3"
    local reason
    case "$rc" in
        0)   reason="converged" ;;
        1)   reason="max_iterations" ;;
        2)   reason="plateau" ;;
        3)   reason="divergence" ;;
        4)   reason="config_invalid" ;;
        130) reason="aborted" ;;
        *)   reason="error" ;;
    esac
    eb_emit_event "cycle.complete" \
        "cycle_id=$cycle_id" "iter=${_CYCLE_LAST_ITERATIONS}" \
        "reason=$reason" 2>/dev/null || true
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

        # Dispatch the cycle's stages in order.
        if ! _cycle_iter_dispatch "$iter" "$state_file"; then
            _CYCLE_LAST_TERMINATED_REASON="error"
            _cycle_clear_traps
            { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
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

        # Decide overall status for the SINGLE atomic write (ADR-021: never
        # split state writes within an iter boundary).
        local overall_status="in_progress"
        local term_rc=-1
        if [[ "$converged" -eq 0 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="converged"
            overall_status="complete"; term_rc=0
        elif _cycle_check_max_iterations "$iter" "$_CYCLE_MAX_ITER"; then
            _CYCLE_LAST_TERMINATED_REASON="max_iterations"
            overall_status="max_iterations"; term_rc=1
        elif _cycle_detect_plateau "$history_file" "$_CYCLE_PLATEAU_WINDOW"; then
            _CYCLE_LAST_TERMINATED_REASON="plateau"
            overall_status="plateau"; term_rc=2
        elif _cycle_detect_divergence "$history_file" "$_CYCLE_DIVERGENCE_WINDOW"; then
            _CYCLE_LAST_TERMINATED_REASON="divergence"
            overall_status="divergence"; term_rc=3
        fi

        # Single atomic state write per iter boundary.
        _cycle_state_write_iter_atomic "$state_file" "$cycle_id" "$iter" \
            "$h_verdict" "$h_status" "$failure_count" "$overall_status" || true

        eb_emit_event "cycle.iteration.complete" \
            "cycle_id=$cycle_id" "iter=$iter" "verdict=$h_verdict" \
            "velocity=$(( 0 - failure_count ))" \
            "failure_count=$failure_count" 2>/dev/null || true

        if [[ $term_rc -ge 0 ]]; then
            case "$term_rc" in
                0) _cycle_handle_terminal_rc 0 "$cycle_id" "$state_file" ;;
                1) eb_emit_event "cycle.complete" "cycle_id=$cycle_id" "iter=$iter" "reason=max_iterations" 2>/dev/null || true ;;
                2) eb_emit_event "cycle.plateau" "cycle_id=$cycle_id" "iter=$iter" "evidence=verdict_tuple_identical" "streak=$_CYCLE_PLATEAU_WINDOW" 2>/dev/null || true
                   eb_emit_event "cycle.complete" "cycle_id=$cycle_id" "iter=$iter" "reason=plateau" 2>/dev/null || true ;;
                3) eb_emit_event "cycle.divergence" "cycle_id=$cycle_id" "iter=$iter" "velocity_history=$failure_count" 2>/dev/null || true
                   eb_emit_event "cycle.complete" "cycle_id=$cycle_id" "iter=$iter" "reason=divergence" 2>/dev/null || true ;;
            esac
            _cycle_clear_traps
            { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return "$term_rc"; }
        fi

        # Not terminating — wire feedback for next iter.
        if ! _cycle_apply_feedback "$(( iter + 1 ))" "$state_dir"; then
            _CYCLE_LAST_TERMINATED_REASON="feedback_missing"
            _cycle_state_write_iter_atomic "$state_file" "$cycle_id" "$iter" \
                "$h_verdict" "$h_status" "$failure_count" "aborted" || true
            eb_emit_event "cycle.complete" \
                "cycle_id=$cycle_id" "iter=$iter" "reason=aborted" \
                2>/dev/null || true
            _cycle_clear_traps
            { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
        fi
    done

    # Loop fell through without hitting max_iterations in the body — defensive
    _CYCLE_LAST_TERMINATED_REASON="max_iterations"
    _cycle_clear_traps
    { [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 1; }
}
