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
# #833: cycle INPUT/OUTPUT boundary banners go through the stage-io chokepoint
# (kind=cycle). The runner's main process does NOT otherwise source stage-io
# (only plugin subshells do, via route.sh), so source it here. stage-io.sh has
# its own load guard, so this is a no-op when already sourced.
# shellcheck source=../output/stage-io.sh
source "$_CYCLE_ORCH_ROOT/core/output/stage-io.sh"
# #511 F2 Pin 2: resolve feedback source paths via the from-stage manifest's
# outputs[id==<X>].path entry (so the orchestrator stops assuming the legacy
# `artifacts/<stage>/<output>` layout that real plugins do NOT follow).
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$_CYCLE_ORCH_ROOT/scripts/lib/manifest-graph.sh"
# ADR-039 (#1132): a cycle member may be a `type: parallel` group — dispatch it
# via the A2 parallel orchestrator. Load guard makes this a no-op when already
# sourced; parallel-orchestrator.sh does NOT source us back (no cycle).
# shellcheck source=./parallel-orchestrator.sh
source "$_CYCLE_ORCH_ROOT/core/pipeline/parallel-orchestrator.sh"
# #1822: the disposition response table, for the dispatch event.
# shellcheck source=./disposition.sh
source "$_CYCLE_ORCH_ROOT/core/pipeline/disposition.sh"

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
_CYCLE_VELOCITY_PLATEAU_WINDOW=0  # 0 = disabled until template sets velocity_plateau.window
_CYCLE_LAST_PLATEAU_EVIDENCE=""

# #1284 (ADR-047): multi-condition exit_when state — populated by _cycle_load_template.
# Empty combinator means single-condition mode (byte-identical behavior).
_CYCLE_EXIT_COMBINATOR=""
_CYCLE_EXIT_CONDITIONS=()

# #833: last-evaluated termination predicate, stashed by _cycle_check_until /
# _cycle_check_abort_when, read by _cycle_render_predicate_result for the
# cycle OUTPUT banner. kind = exit_when | abort_when.
_CYCLE_LAST_PREDICATE_KIND=""
_CYCLE_LAST_PREDICATE_STAGE=""
_CYCLE_LAST_PREDICATE_FIELD=""
_CYCLE_LAST_PREDICATE_OP=""
_CYCLE_LAST_PREDICATE_EXPECTED=""
_CYCLE_LAST_PREDICATE_ACTUAL=""
_CYCLE_LAST_PREDICATE_MATCH=""

# #833: per-iter cycle-banner seq counters, keyed by iter. Holds the reserved
# seq from stage_io_begin so the matching stage_io_end can pair correctly.
declare -gA _CYCLE_IO_SEQ=()

# Internal trap-state (mirrors _route_loop_* convention in route.sh).
_CYCLE_TRAP_CYCLE_ID=""
_CYCLE_TRAP_ITER=0
_CYCLE_TRAP_HISTORY_FILE=""

# ADR-029 G2 (#810): per-member consecutive router-timeout counter.
# Resets on every cycle_orchestrator_run entry. Incremented when a leaf
# member returns verdict=error reason=router_timeout|router_oom_kill;
# zeroed on any non-timeout dispatch.
declare -gA _CYCLE_TIMEOUT_RUN=()

# ADR-029 G3 (#812): per-member max_turns base captured at the FIRST timeout.
# Stores the original (pre-bump) budget so escalation math stays anchored
# even after the override is in effect. Reset on success.
declare -gA _CYCLE_TURNS_BASE=()

# ADR-029 G2/G3 cross-iteration persistence (#844): keyed by cycle_id:stage_name.
# Survive cycle_orchestrator_run re-entry for nested invocations of the same
# cycle_id so stages that burned timeout budget carry their count forward.
declare -gA _CYCLE_TIMEOUT_RUN_PERSIST=()
declare -gA _CYCLE_TURNS_BASE_PERSIST=()

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

# Wave 19-C-1 (#725): always-on predicate-evaluation instrumentation. Emitted
# from _cycle_check_until (kind=exit_when) and _cycle_check_abort_when
# (kind=abort_when) after each evaluation. Lets operators see exactly what
# the predicate compared and whether it matched — answering the "did the
# predicate even fire?" / "what verdict did it actually see?" forensic
# questions without instrumenting the orchestrator post-hoc.
_cycle_emit_predicate() {
    local kind="$1" stage="$2" field="$3" op="$4" expected="$5" actual="$6" match="$7"
    eb_emit_event "cycle.predicate.evaluated" \
        "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" \
        "iter=${_CYCLE_TRAP_ITER:-0}" \
        "kind=$kind" "stage=$stage" "field=$field" "op=$op" \
        "expected=$expected" "actual=$actual" "match=$match" \
        2>/dev/null || true
}

# Wave 19-D-1 (#731): per-member dispatch instrumentation. Emitted by
# _cycle_iter_dispatch at the start of each member's dispatch (BEFORE the
# nested-cycle recursion or leaf cycle_dispatch_stage call) and at the
# complete boundary (AFTER rc is captured and verdict is mapped). Answers
# "did the for-loop reach member X?" deterministically from events.jsonl —
# without these, the dogfood 20260605140602-80831 forensics required
# code-reading to deduce that review was never dispatched.
_cycle_emit_member_dispatch_start() {
    local position="$1" member="$2" kind="$3"
    eb_emit_event "cycle.member.dispatch.start" \
        "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" \
        "iter=${_CYCLE_TRAP_ITER:-0}" \
        "position=$position" "member=$member" "kind=$kind" \
        2>/dev/null || true
}

# #1822 (ADR-054 §6): the dispatch event carries the resolved `disposition` and the
# engine's response to it, so an operator can see WHY a stage was treated as
# recoverable — or why it was not — without inferring it from an rc.
#
# Read off the _CYCLE_DISPATCH_DISPOSITION channel rather than taken as a sixth
# positional arg: this function has nine call sites, most of them abort paths
# that have no disposition to pass, and the channel is how cycle_id/iter already
# reach here. An empty value is reported as empty — a v1 stage declares no
# disposition, and the event must not invent one.
_cycle_emit_member_dispatch_complete() {
    local position="$1" member="$2" rc="$3" verdict="$4" status="$5"
    local _disp="${_CYCLE_DISPATCH_DISPOSITION:-}" _disp_resp=""
    # Spelled as an `if` rather than `[[ ... ]] && ...`: under errexit a failing
    # && list is only safe because another command follows it, which is a
    # property of the surrounding code rather than of this line.
    if [[ -n "$_disp" ]]; then
        _disp_resp="$(disposition_response "$_disp" 2>/dev/null || true)"
    fi
    eb_emit_event "cycle.member.dispatch.complete" \
        "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" \
        "iter=${_CYCLE_TRAP_ITER:-0}" \
        "position=$position" "member=$member" \
        "rc=$rc" "verdict=$verdict" "status=$status" \
        "disposition=$_disp" "disposition_response=$_disp_resp" \
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
    _CYCLE_TRAP_CYCLE_ID=''
    return 130
}

# ─── _cycle_member_is_blocking <stage_id> ────────────────────────────────────
# ADR-013 blocking table (CQ-3 / issue #863). Reads the template-parsed
# _TPL_STAGE_BLOCKING_<safe_id> export set by template.sh from the `blocking:`
# YAML attribute. Returns 0 when the member halts the cycle on failure.
_cycle_member_is_blocking() {
    local _blk_safe="${1//-/_}"
    local _blk_var="_TPL_STAGE_BLOCKING_${_blk_safe}"
    [[ "${!_blk_var:-}" == "true" ]]
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
#   _CYCLE_PLATEAU_WINDOW / _CYCLE_DIVERGENCE_WINDOW / _CYCLE_VELOCITY_PLATEAU_WINDOW
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
    # #1284 (ADR-047): multi-condition exit_when state.
    _CYCLE_EXIT_COMBINATOR=""
    _CYCLE_EXIT_CONDITIONS=()
    _CYCLE_PLATEAU_WINDOW="$_CYCLE_DEFAULT_PLATEAU_WINDOW"
    _CYCLE_DIVERGENCE_WINDOW="$_CYCLE_DEFAULT_DIVERGENCE_WINDOW"
    _CYCLE_VELOCITY_PLATEAU_WINDOW=0  # 0 = disabled; only set when template has velocity_plateau.window

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

    # #1284 (ADR-047): check for multi-condition exit_when first. When present,
    # the single-condition _TPL_CYCLE_UNTIL_* vars are empty — skip their validation.
    local ew_comb_var="_TPL_CYCLE_EXIT_COMBINATOR_${safe}"
    local ew_count_var="_TPL_CYCLE_EXIT_COUNT_${safe}"
    _CYCLE_EXIT_COMBINATOR="${!ew_comb_var:-}"
    if [[ -n "$_CYCLE_EXIT_COMBINATOR" ]]; then
        case "$_CYCLE_EXIT_COMBINATOR" in
            all|any) ;;
            *)
                error "cycle '$cycle_id': exit_when combinator must be all|any, got: $_CYCLE_EXIT_COMBINATOR"
                _cycle_emit "cycle.config.invalid" "reason=exit_when_combinator_invalid" \
                    "value=$_CYCLE_EXIT_COMBINATOR"
                return 4
                ;;
        esac
        local ew_count="${!ew_count_var:-0}"
        if ! [[ "$ew_count" =~ ^[0-9]+$ ]] || [[ "$ew_count" -lt 1 ]]; then
            error "cycle '$cycle_id': exit_when multi-condition count must be >=1, got: $ew_count"
            _cycle_emit "cycle.config.invalid" "reason=exit_when_count_invalid"
            return 4
        fi
        local ew_i ew_s ew_f ew_o ew_v
        for (( ew_i=1; ew_i<=ew_count; ew_i++ )); do
            local _sv="_TPL_CYCLE_EXIT_${ew_i}_STAGE_${safe}"
            local _fv="_TPL_CYCLE_EXIT_${ew_i}_FIELD_${safe}"
            local _ov="_TPL_CYCLE_EXIT_${ew_i}_OP_${safe}"
            local _vv="_TPL_CYCLE_EXIT_${ew_i}_VALUE_${safe}"
            ew_s="${!_sv:-}"; ew_f="${!_fv:-}"; ew_o="${!_ov:-}"; ew_v="${!_vv:-}"
            if [[ -z "$ew_s" || -z "$ew_f" || -z "$ew_o" || -z "$ew_v" ]]; then
                error "cycle '$cycle_id': exit_when condition $ew_i: {stage,field,op,value} all required"
                _cycle_emit "cycle.config.invalid" "reason=exit_when_condition_incomplete" "index=$ew_i"
                return 4
            fi
            case "$ew_f" in
                verdict|status) ;;
                *)
                    error "cycle '$cycle_id': exit_when condition $ew_i: field must be verdict|status, got: $ew_f"
                    _cycle_emit "cycle.config.invalid" "reason=exit_when_field_invalid" "value=$ew_f"
                    return 4
                    ;;
            esac
            case "$ew_o" in
                eq|ne) ;;
                *)
                    error "cycle '$cycle_id': exit_when condition $ew_i: op must be eq|ne, got: $ew_o"
                    _cycle_emit "cycle.config.invalid" "reason=exit_when_op_invalid" "value=$ew_o"
                    return 4
                    ;;
            esac
            local _cs_ok=0 _cs
            for _cs in "${_CYCLE_STAGES[@]}"; do
                [[ "$_cs" == "$ew_s" ]] && _cs_ok=1 && break
            done
            if [[ $_cs_ok -ne 1 ]]; then
                error "cycle '$cycle_id': exit_when condition $ew_i: stage '$ew_s' is not in cycle stages (${_CYCLE_STAGES[*]})"
                _cycle_emit "cycle.config.invalid" "reason=exit_when_stage_outside_cycle" "value=$ew_s"
                return 4
            fi
            _CYCLE_EXIT_CONDITIONS+=("${ew_s}|${ew_f}|${ew_o}|${ew_v}")
        done
    else
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
    fi

    local pw="${!pw_var:-}"; [[ -n "$pw" && "$pw" =~ ^[0-9]+$ ]] && _CYCLE_PLATEAU_WINDOW="$pw"
    local dw="${!dw_var:-}"; [[ -n "$dw" && "$dw" =~ ^[0-9]+$ ]] && _CYCLE_DIVERGENCE_WINDOW="$dw"
    local vpw_var="_TPL_CYCLE_VELOCITY_PLATEAU_W_${safe}"
    local vpw="${!vpw_var:-}"; [[ -n "$vpw" && "$vpw" =~ ^[0-9]+$ ]] && _CYCLE_VELOCITY_PLATEAU_WINDOW="$vpw"

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

# ─── _cycle_eval_one_condition <blob> <stage> <field> <op> <expected> ─────────
# Evaluate a single predicate against the blob. Returns 0 (match) or 1 (no match).
# Emits cycle.iteration.verdict_missing when the field is absent.
# Does NOT stash the predicate (caller decides which one to stash for the banner).
_cycle_eval_one_condition() {
    local blob="$1" stage="$2" field="$3" op="$4" expected="$5"
    local actual
    actual="$(jq -r --arg s "$stage" --arg f "$field" \
        '.[$s][$f] // empty' <<< "$blob" 2>/dev/null || true)"
    if [[ -z "$actual" || "$actual" == "null" ]]; then
        _cycle_emit "cycle.iteration.verdict_missing" \
            "iter=$_CYCLE_TRAP_ITER" "stage=$stage" "field=$field"
        _cycle_emit_predicate "exit_when" "$stage" "$field" "$op" "$expected" "" "false"
        return 1
    fi
    local _match="false"
    local _rc=1
    case "$op" in
        eq) [[ "$actual" == "$expected" ]] && { _match="true"; _rc=0; } ;;
        ne) [[ "$actual" != "$expected" ]] && { _match="true"; _rc=0; } ;;
    esac
    _cycle_emit_predicate "exit_when" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    return $_rc
}

# ─── _cycle_check_until <stage_verdicts_jsonblob> ────────────────────────────
# Returns 0 if predicate satisfied (converged), 1 otherwise.
# Stage-verdicts blob is JSON: {"<stage>":{"verdict":"pass","status":"complete"}}.
# Field-missing → 1 (NEVER falsely converge). Emits verdict_missing once.
# #1284 (ADR-047): when _CYCLE_EXIT_COMBINATOR is set, evaluates N conditions
# with all/any logic. Single-condition path is BYTE-IDENTICAL to prior behavior.
_cycle_check_until() {
    local blob="$1"

    # #1284: multi-condition path.
    if [[ -n "${_CYCLE_EXIT_COMBINATOR:-}" && ${#_CYCLE_EXIT_CONDITIONS[@]} -gt 0 ]]; then
        # all: start converged, fail on first miss. any: start diverged, pass on first hit.
        local _ew_overall_rc _ew_cond _ew_s _ew_f _ew_o _ew_v _ew_rc _ew_rest
        local _ew_last_stage="" _ew_last_field="" _ew_last_op="" _ew_last_expected="" _ew_last_match="false"
        [[ "$_CYCLE_EXIT_COMBINATOR" == "all" ]] && _ew_overall_rc=0 || _ew_overall_rc=1
        # Save errexit state before loop — toggling set -e/+e per-iteration leaks the
        # restored set -e to our caller when we return rc=1, triggering their errexit.
        local _ew_had_e=0; [[ "$-" == *e* ]] && _ew_had_e=1; set +e
        for _ew_cond in "${_CYCLE_EXIT_CONDITIONS[@]}"; do
            _ew_s="${_ew_cond%%|*}"; _ew_rest="${_ew_cond#*|}"
            _ew_f="${_ew_rest%%|*}"; _ew_rest="${_ew_rest#*|}"
            _ew_o="${_ew_rest%%|*}"; _ew_v="${_ew_rest#*|}"
            _cycle_eval_one_condition "$blob" "$_ew_s" "$_ew_f" "$_ew_o" "$_ew_v"; _ew_rc=$?
            _ew_last_stage="$_ew_s"; _ew_last_field="$_ew_f"
            _ew_last_op="$_ew_o"; _ew_last_expected="$_ew_v"
            if [[ "$_ew_rc" -eq 0 ]]; then
                _ew_last_match="true"
                [[ "$_CYCLE_EXIT_COMBINATOR" == "any" ]] && { _ew_overall_rc=0; break; }
            else
                _ew_last_match="false"
                [[ "$_CYCLE_EXIT_COMBINATOR" == "all" ]] && { _ew_overall_rc=1; break; }
            fi
        done
        [[ $_ew_had_e -eq 1 ]] && set -e
        local _ew_actual
        _ew_actual="$(jq -r --arg s "$_ew_last_stage" --arg f "$_ew_last_field" \
            '.[$s][$f] // empty' <<< "$blob" 2>/dev/null || true)"
        _cycle_stash_predicate "exit_when" "$_ew_last_stage" "$_ew_last_field" \
            "$_ew_last_op" "$_ew_last_expected" "$_ew_actual" "$_ew_last_match"
        return $_ew_overall_rc
    fi

    # Single-condition path — byte-identical to pre-#1284 behavior.
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
        _cycle_emit_predicate "exit_when" "$stage" "$field" "$op" "$expected" "" "false"
        # #833: stash for the cycle OUTPUT banner (missing → empty actual).
        _cycle_stash_predicate "exit_when" "$stage" "$field" "$op" "$expected" "" "false"
        return 1
    fi
    local _match="false"
    local _rc=1
    case "$op" in
        eq) [[ "$actual" == "$expected" ]] && { _match="true"; _rc=0; } ;;
        ne) [[ "$actual" != "$expected" ]] && { _match="true"; _rc=0; } ;;
    esac
    _cycle_emit_predicate "exit_when" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    # #833: stash the just-evaluated predicate so _cycle_render_predicate_result
    # can restate it on the cycle OUTPUT banner.
    _cycle_stash_predicate "exit_when" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    return $_rc
}

# ─── _cycle_stash_predicate — record last predicate eval for OUTPUT banner ───
# #833: the cycle OUTPUT banner restates the most-recently evaluated
# termination predicate. Both _cycle_check_until and _cycle_check_abort_when
# already compute kind/stage/field/op/expected/actual/match; stash them here so
# _cycle_render_predicate_result can format them without recomputation.
_cycle_stash_predicate() {
    _CYCLE_LAST_PREDICATE_KIND="$1"
    _CYCLE_LAST_PREDICATE_STAGE="$2"
    _CYCLE_LAST_PREDICATE_FIELD="$3"
    _CYCLE_LAST_PREDICATE_OP="$4"
    _CYCLE_LAST_PREDICATE_EXPECTED="$5"
    _CYCLE_LAST_PREDICATE_ACTUAL="$6"
    _CYCLE_LAST_PREDICATE_MATCH="$7"
}

# ─── _cycle_render_feedback_digest <iter> <state_dir> (#833) ─────────────────
# Builds the cycle INPUT-banner body: a comma-joined digest of the feedback
# edges consumed this iter. For each edge in _CYCLE_FEEDBACK[] (same parse as
# _cycle_apply_feedback), inspect $state_dir/cycle-<id>/iter-<iter>/feedback/
# <to_field>.txt:
#   present       → "<to_field>(<digest>)"  (verdict from JSON, else ~40-char
#                    head; a source stage that declares
#                    capabilities.feedback_count_field also appends ", N changes")
#   required+miss → "<to_field>(MISSING)"
#   optional+miss → skipped
# iter==1 (or no edges) → "(no feedback — first iteration)".
# Pure/read-only, 2>/dev/null-guarded, never trips errexit.
_cycle_render_feedback_digest() {
    local iter="$1" state_dir="$2"
    if [[ "$iter" == "1" ]] || [[ ${#_CYCLE_FEEDBACK[@]} -eq 0 ]]; then
        printf '(no feedback — first iteration)'
        return 0
    fi
    local fb_dir="$state_dir/cycle-${_CYCLE_TRAP_CYCLE_ID}/iter-${iter}/feedback"
    local -a parts=()
    local rec
    local _fbd_plugins_root="${ZBUILD_PLUGINS_ROOT:-$_CYCLE_ORCH_ROOT/plugins}"
    _manifest_graph_ensure_yaml_get 2>/dev/null || true
    for rec in "${_CYCLE_FEEDBACK[@]}"; do
        # "from_stage:from_output|to_stage:to_field:required"
        local from_part="${rec%%|*}"
        local from_stage="${from_part%%:*}"
        local to_part="${rec#*|}"
        local rest="${to_part#*:}"
        local to_field="${rest%%:*}"
        local required="${rest#*:}"
        local f="$fb_dir/${to_field}.txt"
        if [[ -f "$f" ]]; then
            local content digest
            content="$(cat "$f" 2>/dev/null || true)"
            # Prefer a JSON .verdict; else the first ~40 chars (single line).
            digest="$(jq -r '.verdict // empty' <<< "$content" 2>/dev/null || true)"
            if [[ -z "$digest" ]]; then
                digest="$(printf '%s' "$content" | tr '\n' ' ' | cut -c1-40)"
            fi
            # ADR-047 §4: if the source stage declares capabilities.feedback_count_field,
            # append the length of that JSON array field (no stage name literal).
            local _fb_manifest _fb_count_field=""
            _fb_manifest="$(manifest_graph_resolve_member "$_fbd_plugins_root" "$from_stage" 2>/dev/null)" || true
            if [[ -n "$_fb_manifest" ]]; then
                _fb_count_field="$(yaml_get "$_fb_manifest" "capabilities.feedback_count_field" 2>/dev/null || true)"
            fi
            if [[ -n "$_fb_count_field" ]]; then
                local n_changes
                n_changes="$(jq -r --arg f "$_fb_count_field" '(.[$f] // []) | length' <<< "$content" 2>/dev/null || true)"
                if [[ "$n_changes" =~ ^[0-9]+$ ]]; then
                    digest="${digest}, ${n_changes} changes"
                fi
            fi
            parts+=( "${to_field}(${digest})" )
        elif [[ "$required" == "true" ]]; then
            parts+=( "${to_field}(MISSING)" )
        fi
    done
    if [[ ${#parts[@]} -eq 0 ]]; then
        printf '(no feedback — first iteration)'
        return 0
    fi
    local IFS_save="$IFS"; IFS=','
    printf '%s' "${parts[*]}"
    IFS="$IFS_save"
    return 0
}

# ─── _cycle_read_progress <state_dir> (#1243) ────────────────────────────────
# Code-change PROGRESS axis for the cycle health score. Reads this iteration's
# build-summary.json (files_changed[]/lines_added/lines_removed — the diff the
# build actually applied) and echoes three space-separated ints:
#   "<files_changed> <lines_added> <lines_removed>"
# Absent/malformed summary, no state_dir, or a cycle with no build member all
# read as "0 0 0" (→ "no progress"). Repo-agnostic; pure/read-only; the jq
# fallbacks keep it errexit-safe even on a truncated artifact.
_cycle_read_progress() {
    local state_dir="$1"
    local files=0 add=0 del=0
    local bsj="$state_dir/artifacts/build-summary.json"
    if [[ -n "$state_dir" && -f "$bsj" ]]; then
        files="$(jq -r '(.files_changed // []) | length' "$bsj" 2>/dev/null || echo 0)"
        add="$(jq -r '.lines_added // 0' "$bsj" 2>/dev/null || echo 0)"
        del="$(jq -r '.lines_removed // 0' "$bsj" 2>/dev/null || echo 0)"
    fi
    [[ "$files" =~ ^[0-9]+$ ]] || files=0
    [[ "$add"   =~ ^[0-9]+$ ]] || add=0
    [[ "$del"   =~ ^[0-9]+$ ]] || del=0
    printf '%s %s %s' "$files" "$add" "$del"
    return 0
}

# ─── _cycle_render_predicate_result <iter> [state_dir] (#833, #1241, #1243) ───
# Builds the cycle OUTPUT-banner body from the last-stashed predicate eval:
#   line1: <kind> stage=<s> field=<f> op=<op> value=<v> → MATCHED|NOT MATCHED (got=<actual>)
#   line2 (#1243): multi-axis health score, human-readable, calculation shown.
#   line3 (#1241, NOT MATCHED only): failed gates: <list>[ — <reason>]
# #1243: the old single-axis `velocity=0-fc` was misleading — an iteration that
# applied ZERO code read only as "more defects". The health line now combines
# two axes into one total with the arithmetic visible:
#   code-change PROGRESS (lines_added+lines_removed this iter) − DEFECTS (fc)
#     → SCORE. A zero-diff iter explicitly reads "no progress" (distinct from a
#   regression).
# #1241: the optional <state_dir> also plumbs the gate-aggregator rollup so the
# banner names WHICH gate blocked (not just "NOT MATCHED (got=fail)"); omitted →
# no failed-gates line. Pure/read-only; no errexit hazard.
_cycle_render_predicate_result() {
    local iter="$1"
    local state_dir="${2:-}"
    local kind="${_CYCLE_LAST_PREDICATE_KIND:-exit_when}"
    local stage="${_CYCLE_LAST_PREDICATE_STAGE:-}"
    local field="${_CYCLE_LAST_PREDICATE_FIELD:-}"
    local op="${_CYCLE_LAST_PREDICATE_OP:-}"
    local expected="${_CYCLE_LAST_PREDICATE_EXPECTED:-}"
    local actual="${_CYCLE_LAST_PREDICATE_ACTUAL:-}"
    local match="${_CYCLE_LAST_PREDICATE_MATCH:-false}"
    local fc="${_CYCLE_LAST_FAILURE_COUNT:-0}"
    [[ "$fc" =~ ^[0-9]+$ ]] || fc=0
    local matched_str="NOT MATCHED (got=${actual})"
    [[ "$match" == "true" ]] && matched_str="MATCHED (got=${actual})"

    local files add del
    read -r files add del <<< "$(_cycle_read_progress "$state_dir")"
    local progress=$(( add + del ))
    local score=$(( progress - fc ))
    local health_line
    if [[ "$progress" -eq 0 ]]; then
        # Zero forward code change — surface it as a distinct signal from defects.
        health_line="$(printf 'health: progress=0 (no progress) - defects=%s → score=%s' "$fc" "$score")"
    else
        health_line="$(printf 'health: progress=%s (%s files, +%s/-%s) - defects=%s → score=%s' \
            "$progress" "$files" "$add" "$del" "$fc" "$score")"
    fi
    printf '%s stage=%s field=%s op=%s value=%s → %s\n%s' \
        "$kind" "$stage" "$field" "$op" "$expected" "$matched_str" \
        "$health_line"
    # #1241: on a NOT-MATCHED terminating iter, name the failing gate(s) + reason
    # from the gate-aggregator rollup so the operator sees the cause. A pass
    # (MATCHED) is never annotated with failures. Best-effort/read-only.
    if [[ "$match" != "true" && -n "$state_dir" ]]; then
        local _agg="$state_dir/artifacts/gate-aggregator-result.json"
        if [[ -f "$_agg" ]]; then
            local _failed _reason
            _failed="$(jq -r '(.failed // []) | join(", ")' "$_agg" 2>/dev/null || true)"
            _reason="$(jq -r '.reason // empty' "$_agg" 2>/dev/null || true)"
            if [[ -n "$_failed" ]]; then
                printf '\nfailed gates: %s' "$_failed"
                [[ -n "$_reason" ]] && printf ' — %s' "$_reason"
            fi
        fi
    fi
    return 0
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
    if [[ -z "$actual" || "$actual" == "null" ]]; then
        _cycle_emit_predicate "abort_when" "$stage" "$field" "$op" "$expected" "" "false"
        # #833 NOTE #2: do NOT overwrite the predicate stash here — abort_when
        # did not fire (missing actual), so the cycle OUTPUT banner must keep
        # showing the exit_when evaluation _cycle_check_until already stashed.
        return 1
    fi
    local _match="false"
    local _rc=1
    case "$op" in
        eq) [[ "$actual" == "$expected" ]] && { _match="true"; _rc=0; } ;;
        ne) [[ "$actual" != "$expected" ]] && { _match="true"; _rc=0; } ;;
    esac
    _cycle_emit_predicate "abort_when" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    # #833 NOTE #2: only let abort_when overwrite the OUTPUT-banner predicate
    # stash when it ACTUALLY matched (the terminating predicate). On a normal /
    # converged iter, abort_when evaluates to NOT MATCHED — leaving its eval in
    # the stash would mis-render the banner as `abort_when ... NOT MATCHED`
    # instead of the exit_when evaluation that actually drove the iteration.
    if [[ "$_match" == "true" ]]; then
        _cycle_stash_predicate "abort_when" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    fi
    return $_rc
}

# ─── _cycle_check_route_back <verdicts_blob> ─────────────────────────────────
# #1217 (ADR-045). Mirrors _cycle_check_abort_when against the per-cycle
# _TPL_CYCLE_ROUTE_BACK_{STAGE,FIELD,OP,VALUE}_<cid> predicate. Returns 0 if the
# predicate fired (route back requested), else 1. Missing field → 1 (NEVER
# spuriously reroute). Emits the predicate event (kind=route_back); the caller
# converts a matched terminal into rc=11 and stashes the target for the runner.
_cycle_check_route_back() {
    local blob="$1"
    local safe="${_CYCLE_TRAP_CYCLE_ID//-/_}"
    local stage_var="_TPL_CYCLE_ROUTE_BACK_STAGE_${safe}"
    local stage="${!stage_var:-}"
    local field_var="_TPL_CYCLE_ROUTE_BACK_FIELD_${safe}"
    local field="${!field_var:-}"
    local op_var="_TPL_CYCLE_ROUTE_BACK_OP_${safe}"
    local op="${!op_var:-}"
    local val_var="_TPL_CYCLE_ROUTE_BACK_VALUE_${safe}"
    local expected="${!val_var:-}"
    [[ -z "$stage" || -z "$field" || -z "$op" || -z "$expected" ]] && return 1
    local actual
    actual="$(jq -r --arg s "$stage" --arg f "$field" \
        '.[$s][$f] // empty' <<< "$blob" 2>/dev/null || true)"
    if [[ -z "$actual" || "$actual" == "null" ]]; then
        _cycle_emit_predicate "route_back" "$stage" "$field" "$op" "$expected" "" "false"
        return 1
    fi
    local _match="false"
    local _rc=1
    case "$op" in
        eq) [[ "$actual" == "$expected" ]] && { _match="true"; _rc=0; } ;;
        ne) [[ "$actual" != "$expected" ]] && { _match="true"; _rc=0; } ;;
    esac
    _cycle_emit_predicate "route_back" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    if [[ "$_match" == "true" ]]; then
        _cycle_stash_predicate "route_back" "$stage" "$field" "$op" "$expected" "$actual" "$_match"
    fi
    return $_rc
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
    if [[ "$distinct" == "1" ]]; then
        _CYCLE_LAST_PLATEAU_EVIDENCE="verdict_tuple_identical"
        return 0
    fi
    return 1
}

# ─── _cycle_detect_velocity_plateau <history_file> <window> ──────────────────
# No consecutive pair in the last <window> failure_counts shows a decrease →
# velocity plateau (flat or worsening). Fires BEFORE max_iterations (priority
# 1.5) so a stalled cycle exits early without consuming all iterations.
# Skip + emit cycle.plateau.skipped when iter<2 OR history_lines<window.
_cycle_detect_velocity_plateau() {
    local history_file="$1" window="$2"
    # window=0 means the feature is disabled (no velocity_plateau.window in template).
    [[ "$window" -eq 0 ]] 2>/dev/null && return 1
    if ! [[ "$window" =~ ^[0-9]+$ ]] || [[ "$window" -lt 2 ]]; then
        _cycle_emit "cycle.metric.invalid" "metric=velocity_plateau_window" "value=$window"
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
    # Tail the last <window> rows; extract failure_count values.
    local tail_rows; tail_rows="$(tail -n "$window" "$history_file" 2>/dev/null)"
    local -a fcs=()
    local row
    while IFS= read -r row; do
        local fc; fc="$(jq -r '.failure_count // 0' <<< "$row" 2>/dev/null || echo "0")"
        fcs+=("$fc")
    done <<< "$tail_rows"
    # Plateau if no consecutive pair shows a strict decrease (fc[i] > fc[i+1]).
    local i
    for (( i=0; i < ${#fcs[@]} - 1; i++ )); do
        if (( ${fcs[$i]} > ${fcs[$(( i + 1 ))]} )) 2>/dev/null; then
            return 1  # found a decrease → not a velocity plateau
        fi
    done
    _CYCLE_LAST_PLATEAU_EVIDENCE="velocity_flat"
    return 0
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
    # #1284: for multi-condition, bypass if ANY condition targets "error".
    if [[ "${_CYCLE_UNTIL_VALUE:-}" == "error" ]]; then
        return 1
    fi
    if [[ -n "${_CYCLE_EXIT_COMBINATOR:-}" ]]; then
        local _ew_c
        for _ew_c in "${_CYCLE_EXIT_CONDITIONS[@]}"; do
            [[ "${_ew_c##*|}" == "error" ]] && return 1
        done
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
                # ADR-029 G2 (#810): a verdict=error from this iter that
                # came from a router timeout/OOM is recoverable — the
                # member loop's G2 logic owns the abandon decision and
                # already terminated rc=4 if it hit threshold. If we
                # reached _cycle_detect_blocked, the counter is still
                # under threshold, so let the cycle iterate once more.
                # Without this skip, the first verdict=error would
                # always shadow G2's count-to-2 rule.
                if [[ "$v" == "error" ]] && \
                   [[ -n "${_CYCLE_TIMEOUT_RUN[$s]:-}" ]] && \
                   [[ "${_CYCLE_TIMEOUT_RUN[$s]}" -ge 1 ]]; then
                    continue
                fi
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

# ─── _cycle_resolve_scope_expansion <cycle_id> <state_dir> (#840 / ADR-030) ──
# Reads a scope_expansion_request emitted by a member (build-summary.json),
# resolves it against the cycle's scope_policy via scripts/lib/scope-governance.sh,
# and acts. Echoes the decision: none | grant | deny.
#   grant   → granted paths written to <state_dir>/scope-expansion-grant.txt and
#             exported as ZBUILD_SCOPE_EXPANSION_GRANT (build merges it next iter);
#             the request is cleared so it does not re-trigger; cycle CONTINUES.
#   deny    → caller terminates the cycle with blocked_on_scope (NO loop). Covers
#             the default-off case: a non-expandable cycle resolves every request
#             to deny, so a structurally-blocked build abandons cleanly.
#   none    → no request present; cycle proceeds normally.
# The security floor lives in scope-governance.sh and is unbreachable here.
_cycle_resolve_scope_expansion() {
    local cycle_id="$1" state_dir="$2"
    local safe="${cycle_id//-/_}"

    local bsj="$state_dir/artifacts/build-summary.json"
    [[ -f "$bsj" ]] || { echo "none"; return 0; }

    local req
    req="$(jq -c 'if (.scope_expansion_request? // null) == null then empty
                  elif ((.scope_expansion_request.files? // []) | length) == 0 then empty
                  else .scope_expansion_request end' "$bsj" 2>/dev/null)"
    [[ -z "$req" ]] && { echo "none"; return 0; }

    # Load the resolver core (idempotent source guard inside the lib).
    local _gov="${_ZBUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/scripts/lib/scope-governance.sh"
    # shellcheck source=/dev/null
    [[ -f "$_gov" ]] && source "$_gov"
    if ! declare -F scope_resolve_request >/dev/null 2>&1; then
        # Resolver unavailable — fail safe to deny (clean abandon, never loop).
        echo "deny"; return 0
    fi

    local expandable autogrant escalate
    local ev="_TPL_CYCLE_SCOPE_EXPANDABLE_${safe}"; expandable="${!ev:-false}"
    local av="_TPL_CYCLE_SCOPE_AUTO_GRANT_${safe}"; autogrant="${!av:-}"
    local sv="_TPL_CYCLE_SCOPE_ESCALATE_${safe}";   escalate="${!sv:-none}"

    local decision action
    decision="$(scope_resolve_request "$req" "$expandable" "$autogrant" "$escalate" 2>/dev/null)"
    action="$(jq -r '.action // "deny"' <<<"$decision" 2>/dev/null || echo deny)"

    if [[ "$action" == "grant" ]]; then
        local grant_file="$state_dir/scope-expansion-grant.txt"
        jq -r '.granted[]?' <<<"$decision" 2>/dev/null > "$grant_file"
        export ZBUILD_SCOPE_EXPANSION_GRANT="$grant_file"
        # Clear the request so the same files are not re-granted next iter.
        local _tmp="$bsj.tmp.$$"
        if jq 'del(.scope_expansion_request)' "$bsj" > "$_tmp" 2>/dev/null; then
            mv -f "$_tmp" "$bsj"
        else
            rm -f "$_tmp"
        fi
        eb_emit_event "cycle.scope.granted" "cycle_id=$cycle_id" \
            "files=$(jq -r '[.granted[]?] | join(",")' <<<"$decision" 2>/dev/null)" 2>/dev/null || true
        echo "grant"; return 0
    fi

    # escalate (v1) and deny both end the cycle cleanly — no loop.
    eb_emit_event "cycle.scope.denied" "cycle_id=$cycle_id" \
        "action=$action" "reason=$(jq -r '.reason // ""' <<<"$decision" 2>/dev/null)" 2>/dev/null || true
    echo "deny"; return 0
}

_cycle_apply_feedback() {
    local iter_next="$1" state_dir="$2"
    local fb_dir="$state_dir/cycle-${_CYCLE_TRAP_CYCLE_ID}/iter-${iter_next}/feedback"
    mkdir -p "$fb_dir" 2>/dev/null || true
    export ZBUILD_CYCLE_FEEDBACK_DIR="$fb_dir"

    # ADR-034 / #846: wire targeted-test artifacts for the next iter's test stage.
    # ZBUILD_TEST_RED_SET  → path to test-red-set.json from the just-completed run.
    # ZBUILD_TEST_CHANGED_FILES → comma-separated files_changed[] from build-summary.json.
    # Both are exported (or unset when absent) so _test_run_inner on iter N+1 can
    # build the targeted set without querying the state dir itself.
    local _tr_red_set="$state_dir/artifacts/test-red-set.json"
    if [[ -f "$_tr_red_set" ]]; then
        export ZBUILD_TEST_RED_SET="$_tr_red_set"
    else
        unset ZBUILD_TEST_RED_SET 2>/dev/null || true
    fi
    local _bsj="$state_dir/artifacts/build-summary.json"
    if [[ -f "$_bsj" ]]; then
        local _changed_csv
        _changed_csv="$(jq -r '[.files_changed[]? | tostring] | join(",")' "$_bsj" 2>/dev/null || true)"
        if [[ -n "$_changed_csv" ]]; then
            export ZBUILD_TEST_CHANGED_FILES="$_changed_csv"
        else
            unset ZBUILD_TEST_CHANGED_FILES 2>/dev/null || true
        fi
    else
        unset ZBUILD_TEST_CHANGED_FILES 2>/dev/null || true
    fi

    [[ ${#_CYCLE_FEEDBACK[@]} -eq 0 ]] && return 0

    # ADR-029 G1 (#814): per-feedback-field context budget. Defaults to 50000
    # chars (~12K tokens at 4 chars/token); operators override via env knob
    # ZBUILD_CYCLE_MAX_FIELD_CHARS=<n>. Strategy is tail_truncate (keep the
    # most-recent tail; drop the oldest head — accumulating feedback artifacts
    # tend to grow at the head as agents prepend new diagnostic context).
    # The yaml-level `context_budget.{max_prompt_chars,compress_strategy}`
    # schema declared in ADR-029 G1 is deferred to a follow-up issue; this
    # env-knob path covers the dogfood-observed bloat case (a single
    # prior_test_assessment that ballooned across iters) without needing
    # the template-loader awk parser to grow new keys.
    local _g1_max_field_chars="${ZBUILD_CYCLE_MAX_FIELD_CHARS:-50000}"
    if [[ ! "$_g1_max_field_chars" =~ ^[0-9]+$ ]] || [[ "$_g1_max_field_chars" -le 0 ]]; then
        _g1_max_field_chars=50000
    fi

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
            if [[ "$required" == "true" ]]; then
                _cycle_emit "cycle.feedback.missing" \
                    "iter_next=$iter_next" "from_stage=$from_stage" \
                    "from_output=$from_output" "to_stage=$to_stage" \
                    "to_field=$to_field" "required=$required" \
                    "src=$src"
                return 1
            else
                _cycle_emit "cycle.feedback.absent" \
                    "iter_next=$iter_next" "from_stage=$from_stage" \
                    "from_output=$from_output" "to_stage=$to_stage" \
                    "to_field=$to_field" "required=$required" \
                    "src=$src"
                continue
            fi
        fi
        if ! cp "$src" "$dst" 2>/dev/null; then
            _cycle_emit "cycle.feedback.missing" \
                "iter_next=$iter_next" "from_stage=$from_stage" \
                "to_field=$to_field" "reason=copy_failed"
            return 1
        fi

        # ADR-029 G1: if the copied feedback file exceeds the per-field
        # budget, tail_truncate it in-place. The tail (last N chars) is
        # the most-recent content; prepend a sentinel marker so the
        # downstream agent can see truncation occurred (and won't be
        # misled into thinking that's the entire history).
        local _g1_size
        _g1_size="$(wc -c < "$dst" 2>/dev/null | tr -d ' ' || echo 0)"
        if [[ "$_g1_size" =~ ^[0-9]+$ ]] && [[ "$_g1_size" -gt "$_g1_max_field_chars" ]]; then
            local _g1_marker="… [ADR-029 G1 tail_truncate: dropped $((_g1_size - _g1_max_field_chars)) leading chars; kept tail of $_g1_max_field_chars / $_g1_size] …"
            local _g1_tmp; _g1_tmp="$(mktemp -t zbuild-g1-truncate.XXXXXX 2>/dev/null || true)"
            if [[ -n "$_g1_tmp" ]]; then
                printf '%s\n' "$_g1_marker" > "$_g1_tmp"
                tail -c "$_g1_max_field_chars" "$dst" >> "$_g1_tmp" 2>/dev/null || true
                mv "$_g1_tmp" "$dst" 2>/dev/null || rm -f "$_g1_tmp"
                _cycle_emit "cycle.context.compressed" \
                    "iter_next=$iter_next" "to_field=$to_field" \
                    "from_stage=$from_stage" "from_output=$from_output" \
                    "original_chars=$_g1_size" "final_chars=$_g1_max_field_chars" \
                    "strategy=tail_truncate"
            fi
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

# ─── _cycle_state_write_member_atomic ────────────────────────────────────────
# Persists a cycle member's terminal status and classified verdict into the
# top-level stage_statuses / stage_verdicts maps of pipeline-state.json.
# Uses locked_state_update (same pattern as _cycle_state_write_iter_atomic).
# All call sites use || true — a lock failure must never abort a cycle iter.
_cycle_state_jq_write_member() {
    jq --arg s "$_ZB_CYCLE_MEMBER" \
       --arg st "$_ZB_CYCLE_MEMBER_STATUS" \
       --arg v "$_ZB_CYCLE_MEMBER_VERDICT" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '(.stage_statuses //= {}) | .stage_statuses[$s] = $st
        | (.stage_verdicts //= {}) | .stage_verdicts[$s] = $v
        | .updated_at = $now'
}

_cycle_state_write_member_atomic() {
    local state_file="$1" member="$2" status="$3" verdict="$4"
    export _ZB_CYCLE_MEMBER="$member" \
           _ZB_CYCLE_MEMBER_STATUS="$status" \
           _ZB_CYCLE_MEMBER_VERDICT="$verdict"
    locked_state_update "$state_file" "_cycle_state_jq_write_member" || return 1
    unset _ZB_CYCLE_MEMBER _ZB_CYCLE_MEMBER_STATUS _ZB_CYCLE_MEMBER_VERDICT
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
        # Wave 19-C-2 (#726) defensive clear. Every member dispatch starts
        # from a known-empty RAW baseline. The runner's cycle_dispatch_stage
        # always re-publishes _CYCLE_DISPATCH_VERDICT_RAW (runner.sh:1144)
        # for leaf stages; the nested-cycle branch below also sets it
        # explicitly. Clearing here is belt-and-suspenders for any future
        # dispatch path that forgets to set RAW — empty is preferable to a
        # stale prior-member value bleeding into this member's predicate
        # blob entry at line 870+ below. Mirrors `cycle_dispatch_stage`'s
        # own line 1111-1113 pattern.
        _CYCLE_DISPATCH_VERDICT=""
        _CYCLE_DISPATCH_VERDICT_RAW=""
        _CYCLE_DISPATCH_STATUS=""
        _CYCLE_DISPATCH_REASON=""
        # #1822: same defensive clear. A stale disposition bleeding into the
        # next member's dispatch event would misreport why THAT member stopped.
        _CYCLE_DISPATCH_DISPOSITION=""
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
        # Wave 19-D-1 (#731): emit start event BEFORE dispatching this member.
        # Kind is derived from the type discriminator below — compute it now so
        # the start event records it. Same `_TPL_STAGE_TYPE_<safe>` indirection.
        local _member_type_var_pre="_TPL_STAGE_TYPE_${s//-/_}"
        local _member_kind_pre="${!_member_type_var_pre:-leaf}"
        _cycle_emit_member_dispatch_start "$_cyc_pos" "$s" "$_member_kind_pre"
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
            # build_review_cycle's review→build prior_review_feedback edge, silently
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
            # #845: the termination-window globals are per-cycle config and the
            # nested run reloads them from the INNER cycle's template. They must
            # be restored too, or the inner window leaks into the outer cycle's
            # termination eval. This is benign for plateau/divergence (both
            # default to the same window, so inner==outer in practice) but NOT
            # for velocity_plateau: it defaults to 0 (disabled) and the live
            # build_test_cycle sets window=2, so an unrestored value would make
            # the outer build_review_cycle abandon via velocity-plateau BEFORE its
            # max_iterations check ever runs (regression caught by
            # review-remediation-max-iter-test). Restore all three for the class.
            local _outer_plateau_w="$_CYCLE_PLATEAU_WINDOW"
            local _outer_diverg_w="$_CYCLE_DIVERGENCE_WINDOW"
            local _outer_velopl_w="$_CYCLE_VELOCITY_PLATEAU_WINDOW"
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
            _CYCLE_PLATEAU_WINDOW="$_outer_plateau_w"
            _CYCLE_DIVERGENCE_WINDOW="$_outer_diverg_w"
            _CYCLE_VELOCITY_PLATEAU_WINDOW="$_outer_velopl_w"
            # #1822: the same leak Wave 19-C-2 (#726) fixed for the verdict
            # channel, one channel over. The inner run dispatches its own leaf
            # members, each publishing _CYCLE_DISPATCH_DISPOSITION; on return the
            # outer would emit this nested-cycle member's dispatch event carrying
            # the INNER cycle's last leaf disposition. A nested cycle is not a
            # plugin and declares no disposition — empty is the honest value.
            _CYCLE_DISPATCH_DISPOSITION=""
            [[ $_had_e -eq 1 ]] && set -e
            # Map nested-cycle terminal rc → outer verdict/status.
            # Wave 19-C-2 (#726): set RAW symmetrically with the classified
            # VERDICT so the outer's blob entry for this nested-cycle member
            # has both channels populated. Without this, _CYCLE_DISPATCH_VERDICT_RAW
            # would carry whatever the inner cycle's LAST stage published,
            # leaking inner state into the outer cycle's blob. The outer's
            # predicate (line 870+) reads RAW first, so a leaked inner value
            # would corrupt the outer's verdict accumulation. The nested
            # cycle's own predicates already terminated correctly; the
            # outer's perspective on this member is "converged pass" (rc=0)
            # or "failed fail" (rc!=0).
            # Wave 19-D-1 (#731/#734 Copilot review): emit
            # cycle.member.dispatch.complete BEFORE returning on abort rcs
            # (6/130/143) so the documented start+complete pairing holds
            # even on abort paths. Without this, forensics see a start
            # with no matching complete and cannot reconstruct the
            # dispatched-but-aborted sequence.
            case "$rc" in
                0) _CYCLE_DISPATCH_VERDICT="pass"
                   _CYCLE_DISPATCH_VERDICT_RAW="pass"
                   _CYCLE_DISPATCH_STATUS="complete" ;;
                6) # cycle_abort propagates outward immediately.
                   _CYCLE_LAST_TERMINATED_REASON="cycle_abort"
                   _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "cycle_abort" "aborted"
                   _cycle_state_write_member_atomic "$state_file" "$s" "aborted" "cycle_abort" || true
                   _cycle_clear_traps
                   return 6 ;;
                8) # blocking_member_failure propagates outward.
                   _CYCLE_LAST_TERMINATED_REASON="blocking_member_failure"
                   _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "blocking_member_failure" "failed"
                   _cycle_state_write_member_atomic "$state_file" "$s" "failed" "blocking_member_failure" || true
                   _cycle_clear_traps
                   return 8 ;;
                11) # #1217 (ADR-045): route_back propagates outward to the
                    # runner — only the runner owns dispatch-unit rewind; an
                    # inner cycle cannot rewind the outer loop.
                   _CYCLE_LAST_TERMINATED_REASON="route_back"
                   _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "route_back" "failed"
                   _cycle_state_write_member_atomic "$state_file" "$s" "failed" "route_back" || true
                   _cycle_clear_traps
                   return 11 ;;
                130|143)
                   _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "aborted" "aborted"
                   _cycle_state_write_member_atomic "$state_file" "$s" "aborted" "aborted" || true
                   _cycle_clear_traps
                   return "$rc" ;;
                *) _CYCLE_DISPATCH_VERDICT="fail"
                   _CYCLE_DISPATCH_VERDICT_RAW="fail"
                   _CYCLE_DISPATCH_STATUS="failed" ;;
            esac
            verdict="$_CYCLE_DISPATCH_VERDICT"
            status="$_CYCLE_DISPATCH_STATUS"
            blob="$(jq -c --arg s "$s" --arg v "$verdict" --arg st "$status" \
                '. + {($s): {verdict:$v, status:$st}}' <<< "$blob" 2>/dev/null)" || blob="{}"
            if [[ $rc -ne 0 ]]; then
                fail=$(( fail + 1 ))
            fi
            # Wave 19-D-1 (#731): nested-cycle dispatch.complete with verdict
            # mapped from the nested cycle's terminal rc.
            _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "$verdict" "$status"
            _cycle_state_write_member_atomic "$state_file" "$s" "$_CYCLE_DISPATCH_STATUS" "$_CYCLE_DISPATCH_VERDICT" || true
            continue
        fi
        # ADR-039 (#1132, amends ADR-021): parallel-group-as-member branch.
        # If this member is a `type: parallel` group, run it concurrently via
        # A2's parallel_group_run and map the group's aggregate rc onto this
        # member's verdict blob EXACTLY like the nested-cycle branch above —
        # the group id keys the blob so the cycle's exit_when/abort_when can
        # reference it (e.g. `stage: <gid>, field: verdict, value: pass`).
        if [[ "$_member_type" == "parallel" ]]; then
            if ! declare -F parallel_group_run >/dev/null 2>&1; then
                error "cycle_orchestrator: parallel member '$s' but parallel-orchestrator not loaded"
                _cycle_emit "cycle.config.invalid" "iter=$iter" "stage=$s" \
                    "reason=no_parallel_orchestrator"
                [[ $_had_e -eq 1 ]] && set -e
                return 1
            fi
            set +e
            # The group's members inherit "<member_label>.<slot>" seq labels —
            # export the prefix for the group, save/restore like nested-cycle.
            local _prior_seq_prefix_set=0 _prior_seq_prefix=""
            if [[ -n "${ZBUILD_SEQ_PREFIX+x}" ]]; then
                _prior_seq_prefix_set=1
                _prior_seq_prefix="$ZBUILD_SEQ_PREFIX"
            fi
            export ZBUILD_SEQ_PREFIX="$_member_label"
            parallel_group_run "$s" "$_state_dir" "$state_file"
            rc=$?
            if [[ $_prior_seq_prefix_set -eq 1 ]]; then
                export ZBUILD_SEQ_PREFIX="$_prior_seq_prefix"
            else
                unset ZBUILD_SEQ_PREFIX
            fi
            # The group owned its own INT/TERM traps and cleared them on return;
            # reassert the cycle's ownership for the rest of this iter.
            _cycle_install_traps
            [[ $_had_e -eq 1 ]] && set -e
            # Map group terminal rc → outer verdict/status. rc=0 (all members
            # passed, or on_member_error=continue) → pass; 130/143 (signal)
            # propagate outward; everything else (collect failure / config) → fail.
            case "$rc" in
                0) _CYCLE_DISPATCH_VERDICT="pass"
                   _CYCLE_DISPATCH_VERDICT_RAW="pass"
                   _CYCLE_DISPATCH_STATUS="complete" ;;
                130|143)
                   _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "aborted" "aborted"
                   _cycle_state_write_member_atomic "$state_file" "$s" "aborted" "aborted" || true
                   _cycle_clear_traps
                   return "$rc" ;;
                *) _CYCLE_DISPATCH_VERDICT="fail"
                   _CYCLE_DISPATCH_VERDICT_RAW="fail"
                   _CYCLE_DISPATCH_STATUS="failed" ;;
            esac
            verdict="$_CYCLE_DISPATCH_VERDICT"
            status="$_CYCLE_DISPATCH_STATUS"
            blob="$(jq -c --arg s "$s" --arg v "$verdict" --arg st "$status" \
                '. + {($s): {verdict:$v, status:$st}}' <<< "$blob" 2>/dev/null)" || blob="{}"
            if [[ $rc -ne 0 ]]; then
                fail=$(( fail + 1 ))
            fi
            _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "$verdict" "$status"
            _cycle_state_write_member_atomic "$state_file" "$s" "$_CYCLE_DISPATCH_STATUS" "$_CYCLE_DISPATCH_VERDICT" || true
            continue
        fi
        # ─── ADR-029 G3: per-stage max_turns escalation (#812) ───────────
        # If a previous iter recorded a router timeout for this stage,
        # capture the original (pre-bump) budget so escalation math stays
        # anchored. Then export ZBUILD_ROUTER_MAX_TURNS_OVERRIDE = round
        # (base * 1.5), capped at base * 2. The router's resolver checks
        # this OVERRIDE first (route.sh _route_resolve_max_turns). We
        # unset the override after dispatch so it doesn't leak to sibling
        # members of THIS iter.
        local _g3_prior_override_set=0 _g3_prior_override=""
        if [[ -n "${ZBUILD_ROUTER_MAX_TURNS_OVERRIDE+x}" ]]; then
            _g3_prior_override_set=1
            _g3_prior_override="$ZBUILD_ROUTER_MAX_TURNS_OVERRIDE"
        fi
        if [[ "${_CYCLE_TIMEOUT_RUN[$s]:-0}" -ge 1 ]] \
            && [[ -n "${_CYCLE_TURNS_BASE[$s]:-}" ]]; then
            local _g3_base="${_CYCLE_TURNS_BASE[$s]}"
            # Escalate +50% rounded, cap at 2× base. base must be >0 and
            # finite (the resolver default is 25).
            local _g3_bumped=$(( _g3_base + (_g3_base / 2) ))
            local _g3_cap=$(( _g3_base * 2 ))
            [[ $_g3_bumped -gt $_g3_cap ]] && _g3_bumped=$_g3_cap
            [[ $_g3_bumped -lt 1 ]] && _g3_bumped=1
            export ZBUILD_ROUTER_MAX_TURNS_OVERRIDE="$_g3_bumped"
            eb_emit_event "cycle.member.max_turns.escalated" \
                "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" \
                "iter=$iter" "stage=$s" \
                "base=$_g3_base" "bumped=$_g3_bumped" "cap=$_g3_cap" 2>/dev/null || true
        fi

        set +e
        cycle_dispatch_stage "$s" "$iter" "$state_file"
        rc=$?
        # Restore caller's errexit if they had it on
        [[ $_had_e -eq 1 ]] && set -e

        # Restore the prior G3 override state (if any) so this stage's
        # bump doesn't bleed into the next sibling member's dispatch.
        if [[ $_g3_prior_override_set -eq 1 ]]; then
            export ZBUILD_ROUTER_MAX_TURNS_OVERRIDE="$_g3_prior_override"
        else
            unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE
        fi
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
        # Wave 19-D-1 (#731/#734 Copilot review): emit dispatch.complete
        # BEFORE propagating an abort rc so the start+complete pairing
        # holds on signal-driven aborts (rc=130/143) and rc=6 from leaf
        # stages. The RAW verdict isn't yet read (predicate-blob update
        # happens BELOW), so report "aborted" as both verdict and status.
        # Use the `|| _propagate_rc=$?` form to BOTH capture the rc AND
        # inhibit errexit at the call site (the same reason the prior
        # `|| return $?` form was chosen — see runner.sh:1278 comment).
        # `if ! _zbuild_propagate_abort ...; then $?` loses the original
        # rc because bash's `!` resets $? to 0/1 of the negation.
        local _propagate_rc=0
        _zbuild_propagate_abort "$rc" || _propagate_rc=$?
        if [[ $_propagate_rc -ne 0 ]]; then
            _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "aborted" "aborted"
            # #1800: the leaf branch's own abort propagation (rc 6/9/10/130/143).
            # Pairs the state write with the event on the same terms as the
            # nested-cycle and parallel-group propagate-outward paths.
            _cycle_state_write_member_atomic "$state_file" "$s" "aborted" "aborted" || true
            return "$_propagate_rc"
        fi
        # Wave 19-A (#717): prefer the RAW verdict for cycle predicate
        # evaluation (exit_when / abort_when / until compare against the raw
        # template-declared value, e.g. `value: approve`). Fall back to the
        # classified _CYCLE_DISPATCH_VERDICT for back-compat with dispatch
        # hooks (test stubs, future strategies) that have not yet been
        # updated to publish the raw channel. The classified value remains
        # authoritative for state_helpers.sh's .stage_verdicts contract and
        # the operator-facing stage.complete event — only the in-cycle
        # predicate-evaluation blob switches to raw.
        verdict="${_CYCLE_DISPATCH_VERDICT_RAW:-${_CYCLE_DISPATCH_VERDICT:-}}"
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
        # Wave 19-D-1 (#731): leaf-dispatch complete event. Mirrors the
        # nested-cycle path above. Reports the RAW verdict (the value
        # already used in the predicate-evaluation blob), the rc the
        # dispatch returned, and the status string.
        _cycle_emit_member_dispatch_complete "$_cyc_pos" "$s" "$rc" "$verdict" "$status"
        # Persist classified verdict+status to the top-level stage maps so all
        # dispatched cycle members appear in stage_statuses / stage_verdicts.
        # Uses _CYCLE_DISPATCH_VERDICT (classified) not the raw `verdict` local.
        # Falls back to "missing" on the same terms as the predicate blob above:
        # a hook that publishes only the raw channel would otherwise write an
        # empty string here while the blob reads "missing", and the two records
        # of the same dispatch would disagree.
        _cycle_state_write_member_atomic "$state_file" "$s" \
            "${_CYCLE_DISPATCH_STATUS:-missing}" "${_CYCLE_DISPATCH_VERDICT:-missing}" || true

        # CQ-3 / ADR-013 (#863): blocking member enforcement. If the member
        # is in the ADR-013 blocking table and returned non-zero, halt the
        # cycle immediately (rc=8) so the pipeline can emit status=failed.
        if [[ $rc -ne 0 ]] && _cycle_member_is_blocking "$s"; then
            _cycle_emit "cycle.member.blocking_failure" \
                "iter=$iter" "stage=$s" "rc=$rc"
            _CYCLE_LAST_TERMINATED_REASON="blocking_member_failure"
            _CYCLE_LAST_VERDICTS_BLOB="$blob"
            _CYCLE_LAST_FAILURE_COUNT="$fail"
            [[ $_had_e -eq 1 ]] && set -e
            return 8
        fi

        # ─── ADR-029 G2 abandon REMOVED (#1208); G3 escalation retained ──
        # ADR-029 G2 used to ABANDON the cycle (return 4) on the 2nd consecutive
        # router_timeout/oom member dispatch. Issue #1208 reverses that: a timeout
        # is NEVER fatal — the ONLY fatal condition is the cycle exhausting
        # max_iterations without a clean, passing convergence. So the fast-abandon
        # is gone; a timed-out attempt simply consumes an iteration and the cycle
        # retries (each attempt is cheap — the build self-yields on an empty diff).
        # We KEEP the per-member timeout counter + G3 max_turns base capture (a
        # "needs more turns" escalation is still helpful and non-fatal) and the
        # cycle.member.timeout event for forensics. NB: with #1208 Changes 1-2 a
        # build timeout now surfaces as verdict=did_not_finish (not verdict=error
        # reason=router_timeout), so for the build/test cycle this branch is
        # largely dormant; it stays intact for any member that still reports an
        # error-class router_timeout/oom so G3 escalation continues to work.
        local _g2_reason="${_CYCLE_DISPATCH_REASON:-}"
        if [[ "$verdict" == "error" ]] && \
           [[ "$_g2_reason" == "router_timeout" || "$_g2_reason" == "router_oom_kill" ]]; then
            _CYCLE_TIMEOUT_RUN["$s"]=$(( ${_CYCLE_TIMEOUT_RUN["$s"]:-0} + 1 ))
            # Sync to persist map so the incremented count survives re-entry.
            _CYCLE_TIMEOUT_RUN_PERSIST["${_CYCLE_TRAP_CYCLE_ID}:$s"]="${_CYCLE_TIMEOUT_RUN[$s]}"
            # ADR-029 G3: capture max_turns base on FIRST timeout so the
            # next iter dispatches with an escalated budget. If a per-stage
            # template override exists, use it; otherwise fall back to env;
            # otherwise the compile-time default (25). Calling the template
            # helper directly (mirrors _route_resolve_max_turns logic) so the
            # captured base is the actual budget that was just exhausted.
            if [[ -z "${_CYCLE_TURNS_BASE[$s]:-}" ]]; then
                local _g3_capture=""
                if command -v template_stage_router_max_turns >/dev/null 2>&1; then
                    _g3_capture="$(template_stage_router_max_turns "$s" 2>/dev/null || true)"
                fi
                if [[ ! "$_g3_capture" =~ ^[0-9]+$ ]] || [[ "$_g3_capture" -le 0 ]]; then
                    if [[ "${ZBUILD_ROUTER_MAX_TURNS:-}" =~ ^[0-9]+$ ]] && [[ "${ZBUILD_ROUTER_MAX_TURNS}" -gt 0 ]]; then
                        _g3_capture="$ZBUILD_ROUTER_MAX_TURNS"
                    else
                        _g3_capture="25"
                    fi
                fi
                _CYCLE_TURNS_BASE["$s"]="$_g3_capture"
                _CYCLE_TURNS_BASE_PERSIST["${_CYCLE_TRAP_CYCLE_ID}:$s"]="$_g3_capture"
            fi
            eb_emit_event "cycle.member.timeout" \
                "cycle_id=${_CYCLE_TRAP_CYCLE_ID:-unknown}" \
                "iter=$iter" "stage=$s" \
                "reason=$_g2_reason" \
                "consecutive=${_CYCLE_TIMEOUT_RUN[$s]}" 2>/dev/null || true
            # #1208: NO abandon here — the timeout is non-fatal; the cycle
            # iterates (or, at exhaustion, the by-severity cascade routes the
            # outcome). Only max_iterations-without-convergence is fatal.
        else
            # Reset the per-member counter on any successful (or non-timeout)
            # dispatch — only CONSECUTIVE timeouts trigger fast-abandon.
            _CYCLE_TIMEOUT_RUN["$s"]=0
            _CYCLE_TIMEOUT_RUN_PERSIST["${_CYCLE_TRAP_CYCLE_ID}:$s"]=0
            # ADR-029 G3: also clear the captured base so a future timeout
            # re-anchors from the (possibly re-tuned) current budget.
            unset "_CYCLE_TURNS_BASE[$s]"
            unset "_CYCLE_TURNS_BASE_PERSIST[${_CYCLE_TRAP_CYCLE_ID}:$s]"
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
    # #511 Pin 10 / ADR-047 §4: failure_count fidelity. The orchestrator's
    # default is the count of stages with rc!=0 (always 0..|stages|). For a
    # build/test cycle that under-reports actual progress — a test run that
    # drops from 17 failing tests to 3 looks identical (fc=1 either way),
    # masking convergence and starving the divergence detector. Scan members
    # for one declaring capabilities.detailed_failure_count; read the artifact
    # + field it specifies (no literal stage name or filename).
    local _dfc_plugins_root="${ZBUILD_PLUGINS_ROOT:-$_CYCLE_ORCH_ROOT/plugins}"
    local _dfc_ts _dfc_manifest _dfc_artifact _dfc_field
    for _dfc_ts in "${_CYCLE_STAGES[@]}"; do
        _dfc_manifest="$(manifest_graph_resolve_member "$_dfc_plugins_root" "$_dfc_ts" 2>/dev/null)" || continue
        _dfc_artifact="$(manifest_graph_capability_field "$_dfc_manifest" \
            "detailed_failure_count" "artifact" 2>/dev/null)" || continue
        _dfc_field="$(manifest_graph_capability_field "$_dfc_manifest" \
            "detailed_failure_count" "field" 2>/dev/null)" || continue
        [[ -n "$_dfc_artifact" && -n "$_dfc_field" ]] || continue
        # Defense-in-depth: the manifest-declared artifact name is interpolated
        # into a filesystem path. Reject anything but a plain filename so a
        # manifest value with '/' or '..' can never read outside artifacts/.
        [[ "$_dfc_artifact" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        local _tr="$_state_dir/artifacts/$_dfc_artifact"
        if [[ -s "$_tr" ]]; then
            local _failed_n
            _failed_n="$(jq -r --arg f "$_dfc_field" '.[$f] // 0' "$_tr" 2>/dev/null || echo 0)"
            if [[ "$_failed_n" =~ ^[0-9]+$ ]]; then
                _CYCLE_LAST_FAILURE_COUNT="$_failed_n"
            fi
        fi
        break
    done
    return 0
}

# ─── _cycle_member_terminal_failure <state_dir> (#1044, #1188, Phase 2) ───────
# GENERIC member-disposition contract (ADR-021). Replaces the acceptance-gate-
# specific check: the engine no longer knows ANY plugin id, artifact filename, or
# failure-class vocabulary. It iterates THIS cycle's member roster (_CYCLE_STAGES,
# == _TPL_CYCLE_STAGES_<id>) and, for each member whose recorded result artifact
# declares verdict==fail, reads the generic `disposition` field:
#   terminal    → HALT (this function returns 0, echoing the member id so the
#                 caller carries it in event data).
#   recoverable → NON-terminal (fed back to build via the #951 edge — the cycle
#                 loops but the pipeline does not hard-fail).
#   advisory    → NON-terminal (infra flake / non-blocking).
#   absent      → NON-terminal (fail-safe: only an EXPLICIT terminal halts, so a
#                 disposition-unaware plugin never hard-fails the pipeline).
# Member→manifest→artifact resolution reuses the SHARED roster mechanism
# (manifest_graph_resolve_member / manifest_graph_result_filename) — identical to
# the gate-aggregator. jq absence / missing artifact / parse failure on a member
# is skipped (never falsely blocks). rc 1 when no member is terminal.
# #1220: on a terminal member, exposes its id and its GENERIC human `reason`
# string via globals so the caller can surface a specific operator message
# instead of the opaque "member_terminal_failure". The reason field is read
# verbatim (still no plugin vocabulary in the engine — any plugin may provide it).
# Globals are set even under command substitution's stdout-capture; the caller
# reads them directly (no subshell) so they survive.
_CYCLE_TERMINAL_MEMBER_ID=""
_CYCLE_TERMINAL_MEMBER_REASON=""
_cycle_member_terminal_failure() {
    local state_dir="$1"
    _CYCLE_TERMINAL_MEMBER_ID=""
    _CYCLE_TERMINAL_MEMBER_REASON=""
    command -v jq >/dev/null 2>&1 || return 1
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_CYCLE_ORCH_ROOT/plugins}"
    local artifacts_dir="$state_dir/artifacts"
    local member manifest file result disp
    for member in "${_CYCLE_STAGES[@]}"; do
        [[ -z "$member" ]] && continue
        manifest="$(manifest_graph_resolve_member "$plugins_root" "$member" 2>/dev/null)" || continue
        file="$(manifest_graph_result_filename "$manifest" 2>/dev/null)" || continue
        [[ -z "$file" ]] && continue
        result="$artifacts_dir/$file"
        [[ -s "$result" ]] || continue
        jq -e '.verdict == "fail"' "$result" >/dev/null 2>&1 || continue
        disp="$(jq -r '.disposition // ""' "$result" 2>/dev/null || echo "")"
        if [[ "$disp" == "terminal" ]]; then
            _CYCLE_TERMINAL_MEMBER_ID="$member"
            _CYCLE_TERMINAL_MEMBER_REASON="$(jq -r '.reason // ""' "$result" 2>/dev/null || echo "")"
            printf '%s' "$member"
            return 0
        fi
    done
    return 1
}

# ─── _cycle_read_test_run_mode (ADR-034 / #846) ─────────────────────────────
# Reads the run_mode field from artifacts/test-results.json in the given
# state_dir. Echoes "targeted" or "full". Defaults to "full" on any read
# failure (missing file, missing field, jq error) — fail-closed: unknown mode
# never suppresses convergence.
# Usage: _cycle_read_test_run_mode <state_dir>
_cycle_read_test_run_mode() {
    local state_dir="$1"
    local trj="$state_dir/artifacts/test-results.json"
    if [[ -s "$trj" ]]; then
        local _mode
        _mode="$(jq -r '.run_mode // "full"' "$trj" 2>/dev/null || echo "full")"
        case "$_mode" in
            targeted|full) printf '%s' "$_mode"; return 0 ;;
        esac
    fi
    printf 'full'
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
        # #1117: rc=2 is the plateau-class soft-continue bucket. The no-progress
        # stall-break shares this rc but sets a distinct _CYCLE_LAST_TERMINATED_REASON
        # ("stalled"); prefer it so cycle.complete restates the real terminal
        # reason. Genuine plateau paths set the reason to "plateau", so this is a
        # no-op for them.
        2)   reason="${_CYCLE_LAST_TERMINATED_REASON:-plateau}" ;;
        3)   reason="divergence" ;;
        4)   reason="${_CYCLE_LAST_TERMINATED_REASON:-config_invalid}" ;;
        # rc=5 covers structural `blocked` AND #1265 `no_committed_changes`; both
        # set _CYCLE_LAST_TERMINATED_REASON, so restate it (default: blocked).
        5)   reason="${_CYCLE_LAST_TERMINATED_REASON:-blocked}" ;;
        6)   reason="cycle_abort" ;;
        7)   reason="blocked_on_scope" ;;
        # rc=8 covers two paths, both of which set _CYCLE_LAST_TERMINATED_REASON:
        # ADR-013 blocking:true → "blocking_member_failure" (immediate, rc-only);
        # the ADR-021 disposition=terminal path → "member_terminal_failure".
        8)   reason="${_CYCLE_LAST_TERMINATED_REASON:-blocking_member_failure}" ;;
        # #1217 (ADR-045): rc=11 is a CONTINUE-with-bounded-rewind class, not a
        # halt. The runner translates it into a rewind; this restates the reason
        # on the cycle.complete event for legibility.
        11)  reason="route_back" ;;
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

# ─── _cycle_no_commits_ahead <state_dir> (#1265) ────────────────────────────
# True (rc=0) when the branch HEAD is EQUAL to (0 commits ahead of) the run's
# intake baseline SHA — i.e. this run committed nothing. Reads the bare SHA from
# ${state_dir}/intake-baseline-ref.txt (written by intake). Fail-soft: absent /
# empty baseline, or any git failure → rc=1 (cannot assert → do NOT fire the
# guard, so a resumed/non-intake run never gets a false no_committed_changes).
_cycle_no_commits_ahead() {
    local state_dir="$1"
    local ref_file="$state_dir/intake-baseline-ref.txt"
    [[ -f "$ref_file" ]] || return 1
    local baseline; baseline="$(cat "$ref_file" 2>/dev/null || true)"
    [[ -n "$baseline" ]] || return 1
    local ahead
    ahead="$(git rev-list --count "${baseline}..HEAD" 2>/dev/null || echo -1)"
    [[ "$ahead" == "0" ]]
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

    # ADR-029 G2/G3 cross-iteration persistence (#844): capture the outer cycle's
    # ID before overwriting so we can detect nested re-entry below.
    local _parent_cid="${_CYCLE_TRAP_CYCLE_ID:-}"
    _CYCLE_TRAP_CYCLE_ID="$cycle_id"
    _CYCLE_TRAP_ITER=0
    _CYCLE_LAST_TERMINATED_REASON=""
    # #1217 (ADR-045): reset the route_back hand-off globals per run so a stale
    # target/fallback from a prior cycle can never leak into this one.
    _CYCLE_ROUTE_BACK_TO=""
    _CYCLE_ROUTE_BACK_FALLBACK_RC=""
    # #1227: reset the stashed original reason per run so a stale cause from a
    # prior cycle can never leak into this one's exhausted-path terminal event.
    _CYCLE_ROUTE_BACK_FALLBACK_REASON=""
    # #1225 (ADR-045): reset the edge-owner id per run so a stale owner from a
    # prior cycle can never key the runner's per-edge counter/max onto the wrong
    # cycle. A NESTED cycle sets this to its own id in the by-severity reroute so
    # the runner honors the INNER edge's declared `max`, not the outer unit's.
    _CYCLE_ROUTE_BACK_EDGE_ID=""
    _CYCLE_LAST_ITERATIONS=0
    # #524: reset exit-banner idempotency flag for this cycle run.
    _CYCLE_EXIT_BANNER_EMITTED=0
    _CYCLE_ITER_START_MS=()
    # #833: reset per-iter cycle-banner seq counters for this run.
    _CYCLE_IO_SEQ=()
    # ADR-029 G2 (#810): reset baseline — may be overwritten immediately below
    # if this is a nested re-entry (same cycle_id dispatched by outer iteration).
    _CYCLE_TIMEOUT_RUN=()
    # ADR-029 G3 (#812): per-member max_turns base. Same lifecycle.
    _CYCLE_TURNS_BASE=()
    # ADR-029 G2/G3 cross-iteration persistence (#844): nested re-entry restores
    # accumulated counters so G2/G3 thresholds carry across outer-cycle iters.
    # Top-level entry clears stale persist state to prevent cross-run bleed.
    if [[ -n "$_parent_cid" && "$_parent_cid" != "$cycle_id" ]]; then
        local _pk _pfx="${cycle_id}:"
        for _pk in "${!_CYCLE_TIMEOUT_RUN_PERSIST[@]}"; do
            [[ "$_pk" == "${_pfx}"* ]] && \
                _CYCLE_TIMEOUT_RUN["${_pk#"$_pfx"}"]="${_CYCLE_TIMEOUT_RUN_PERSIST[$_pk]}"
        done
        for _pk in "${!_CYCLE_TURNS_BASE_PERSIST[@]}"; do
            [[ "$_pk" == "${_pfx}"* ]] && \
                _CYCLE_TURNS_BASE["${_pk#"$_pfx"}"]="${_CYCLE_TURNS_BASE_PERSIST[$_pk]}"
        done
    else
        local _pk _pfx="${cycle_id}:"
        for _pk in "${!_CYCLE_TIMEOUT_RUN_PERSIST[@]}"; do
            [[ "$_pk" == "${_pfx}"* ]] && unset "_CYCLE_TIMEOUT_RUN_PERSIST[$_pk]"
        done
        for _pk in "${!_CYCLE_TURNS_BASE_PERSIST[@]}"; do
            [[ "$_pk" == "${_pfx}"* ]] && unset "_CYCLE_TURNS_BASE_PERSIST[$_pk]"
        done
    fi
    # ADR-034 / #846: clear any stale full-suite-gate flag at cycle entry so
    # it does not bleed from a previous cycle invocation in the same process.
    # Must happen here (before any early return) so even config-invalid paths
    # leave the env clean for subsequent callers.
    unset ZBUILD_TEST_FULL_SUITE_GATE 2>/dev/null || true

    if ! _cycle_load_template "$cycle_id"; then
        _CYCLE_LAST_TERMINATED_REASON="config_invalid"
        { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
    fi

    local history_file="$state_dir/cycle-${cycle_id}-history.jsonl"
    _CYCLE_LAST_HISTORY_FILE="$history_file"
    _CYCLE_TRAP_HISTORY_FILE="$history_file"
    : > "$history_file" 2>/dev/null || true

    _cycle_state_init "$state_file" "$cycle_id" "$history_file" "$_CYCLE_MAX_ITER" || {
        error "cycle_orchestrator_run: state init failed for $cycle_id"
        { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
    }

    _cycle_install_traps

    eb_emit_event "cycle.start" \
        "cycle_id=$cycle_id" "iter=1" \
        "max=$_CYCLE_MAX_ITER" \
        "stages=${_CYCLE_STAGES[*]}" 2>/dev/null || true

    # ADR-034 / #846: tracks whether targeted convergence fired in the previous
    # iter (1) → set ZBUILD_TEST_FULL_SUITE_GATE before dispatching this iter.
    local _full_suite_gate_pending=0

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

        # #833: cycle INPUT banner — digest of feedback edges consumed this
        # iter. Build the digest into a var FIRST (command-sub in a var is
        # fine — it's pure), then call stage_io_begin DIRECTLY so its
        # assoc-array seq-reservation side effects persist (we read the
        # reserved seq from _STAGE_IO_LAST_SEQ, the capture_stage_io idiom).
        # kind=cycle forces dests=stdout-only (fd-2) inside stage_io_begin.
        if declare -F stage_io_begin >/dev/null 2>&1; then
            local _cycle_in_digest
            _cycle_in_digest="$(_cycle_render_feedback_digest "$iter" "$state_dir")"
            # Suppress ONLY stdout: stage_io_begin prints the reserved seq on
            # fd 1 (read here from _STAGE_IO_LAST_SEQ), which must NOT leak into
            # the runner stream. Do NOT redirect fd 2 — the banner writes to
            # ${ZBUILD_STAGE_IO_FD:-2}, and a `2>&1` here would swallow it into
            # /dev/null in production (ZBUILD_STAGE_IO_FD unset → fd 2),
            # defeating the entire operator-visible banner (#833 / PR #1039).
            stage_io_begin --kind cycle --stage "$cycle_id" --seq-label "$iter" \
                --input "$_cycle_in_digest" >/dev/null || true
            _CYCLE_IO_SEQ[$iter]="${_STAGE_IO_LAST_SEQ:-}"
        fi

        # ADR-025 (Wave 15-B #684) pre-flight: check the sentinel before
        # starting each new cycle iteration so a SIGINT between iterations
        # is honored at the iter boundary (not buried until the next stage
        # boundary inside _cycle_iter_dispatch).
        if ! _zbuild_check_abort; then
            _CYCLE_LAST_TERMINATED_REASON="aborted"
            _cycle_clear_traps
            { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 130; }
        fi

        # ADR-034 / #846: manage ZBUILD_TEST_FULL_SUITE_GATE lifecycle.
        # If targeted convergence fired last iter, arm the gate env var NOW
        # (before dispatch) so the test stage sees it. Otherwise, ensure any
        # stale value from a prior gate iter is cleared so it cannot bleed.
        if [[ "$_full_suite_gate_pending" -eq 1 ]]; then
            export ZBUILD_TEST_FULL_SUITE_GATE=1
            _full_suite_gate_pending=0
        else
            unset ZBUILD_TEST_FULL_SUITE_GATE 2>/dev/null || true
        fi

        # Dispatch the cycle's stages in order.
        set +e
        _cycle_iter_dispatch "$iter" "$state_file"
        local _iter_rc=$?
        [[ $_ORCH_HAD_E -eq 1 ]] && set -e
        # CQ-3 / ADR-013 (#863): blocking member failure — propagate rc=8 outward
        # immediately so runner.sh can emit pipeline.end status=failed.
        if [[ $_iter_rc -eq 8 ]]; then
            _cycle_clear_traps
            { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 8; }
        fi
        # ADR-025 (Wave 15-B #684): rc=130 from the per-iter dispatch is the
        # abort signal — surface it distinctly from the generic error path
        # (rc=4 / config_invalid) so the runner can map it to
        # pipeline.aborted reason=sigint. Without this branch, the old
        # `if ! _cycle_iter_dispatch` shape collapses 130 into 4.
        if [[ $_iter_rc -eq 130 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="aborted"
            _cycle_clear_traps
            _CYCLE_TRAP_CYCLE_ID=''
            return 130
        fi
        # #1225 (ADR-045): rc=11 from a NESTED member cycle is route_back — it must
        # bubble outward through EVERY enclosing cycle to the runner (only the
        # runner owns dispatch-unit rewind), exactly like rc=8/130 above. Without
        # this branch the generic `-ne 0` catch-all below collapses it to rc=4
        # (config_invalid, silent HALT) and the runner's bounded rewind is never
        # reached. The inner cycle already stashed the hand-off globals
        # (_CYCLE_ROUTE_BACK_{TO,FALLBACK_RC,EDGE_ID}); they survive the
        # nested-dispatch restore block, so just propagate.
        if [[ $_iter_rc -eq 11 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="route_back"
            _cycle_clear_traps
            _CYCLE_TRAP_CYCLE_ID=''
            return 11
        fi
        if [[ $_iter_rc -ne 0 ]]; then
            # #1208: the ADR-029 G2 abandon (rc=4 reason=timeout_abandoned) was
            # removed, so this generic non-zero-dispatch path is the only writer
            # of the reason here — set it unconditionally.
            _CYCLE_LAST_TERMINATED_REASON="error"
            _cycle_clear_traps
            _CYCLE_TRAP_CYCLE_ID=''
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
        # #1117: the build member's raw verdict, for the no-progress stall-break
        # below. Empty for cycles without a `build` member (naturally disables
        # the stall-break there).
        local _build_verdict
        _build_verdict="$(jq -r '.build.verdict // ""' <<< "$verdicts_blob" 2>/dev/null || true)"
        # #1261: generic timeout-tail signal — did ANY member of THIS iteration
        # surface the repo-neutral `did_not_finish` verdict (a router-timeout /
        # dispatch-interrupt mid-flight resting point: build's #1208 verdict,
        # design's #1261 verdict)? Read from the RAW verdict blob — no plugin id /
        # language / path. Consumed ONLY by the reason-aware exhaustion halt below;
        # keying on the TERMINATING iteration is correct because #945 overwrites
        # design.md with the empty timeout marker on each timeout, so a timeout
        # TAIL means the final artifact is empty regardless of earlier content.
        local _iter_did_not_finish=0
        if jq -e 'to_entries | any(.value.verdict == "did_not_finish")' \
                <<< "$verdicts_blob" >/dev/null 2>&1; then
            _iter_did_not_finish=1
        fi

        # Termination evaluation (priority order — see ADR-021, #1208):
        #   1) until satisfied (converged) — UNLESS the build is mid-flight
        #   2) max_iterations (the SINGLE fatal condition) → by-severity
        #   3) blocked (genuine structural error/corrupt/block)
        # (#1208 removed the early velocity_plateau/plateau/divergence terminators
        # and the empty-diff stall-break: the cycle runs ALL its tries; plateau
        # signals only classify the exhaustion outcome, they never stop early.)
        local converged=1
        local _ce=0; case $- in *e*) _ce=1 ;; esac
        set +e; _cycle_check_until "$verdicts_blob"; converged=$?
        [[ $_ce -eq 1 ]] && set -e

        # #1208 — mid-flight build convergence suppression. The test stage ALWAYS
        # runs to verify (the build never short-circuits the cycle), but an
        # iteration may declare `complete` ONLY when the build reached a CLEAN
        # RESTING POINT (LOOP_COMPLETE, or a legitimate empty-diff stall). A build
        # that did NOT finish (router_timeout / dispatch error → verdict
        # did_not_finish) is mid-flight: even if a stale/partial tree spuriously
        # satisfies the gate-aggregator, the iteration must NOT converge. This is
        # NON-FATAL — the cycle iterates (or, at exhaustion, the by-severity
        # cascade routes passing→review / failing→failed). A clean empty_diff
        # stall (nothing-to-do via LOOP_COMPLETE) is a resting point and is NOT
        # suppressed → it converges when the gate verification is green (a done
        # re-run passes on iter 1). GENERIC: keys only on the build member's
        # repo-neutral did_not_finish verdict — no runner/language/path/plugin.
        if [[ "$converged" -eq 0 && "$_build_verdict" == "did_not_finish" ]]; then
            converged=1  # suppress: mid-flight build is not a clean resting point
            _cycle_emit "cycle.build_unfinished.suppressed_convergence" \
                "iter=$iter" "build_verdict=$_build_verdict" \
                "reason=build_mid_flight_not_a_resting_point"
        fi

        # #1265 — no-committed-changes fail-fast. A convergence that would fire
        # with ZERO commits ahead of the intake baseline (e.g. a scope_violation
        # discarded the entire diff, or the tree was never committed) is a FALSE
        # convergence: the branch has nothing to ship, so review passes on an
        # uncommitted tree and `pr` aborts ~38 min later with "No commits between
        # main and branch" (#1214 dogfood). Suppress it here (mirror the
        # did_not_finish pattern) and, unless a governed scope grant lets the next
        # iter commit, terminate no_committed_changes below (rc=5, blocked-class).
        # EXEMPT the legit empty_diff resting point (#1208/#895): "nothing to do"
        # with green gates genuinely converges and has nothing to commit by design.
        #
        # ONLY commit-PRODUCING cycles are subject to this guard: it fires solely
        # when THIS cycle has a commit-producing member in its roster. A build-LESS
        # cycle (design_verify_cycle, or any review/verify cycle) makes no code
        # commits by design — a legitimately-converged such cycle sits at 0 commits
        # ahead of intake and MUST converge normally, never be flagged
        # no_committed_changes. ADR-047 §4: detect commit-producing member via
        # capabilities.produces_commits (manifest-declared, no stage name literal).
        local _has_build_member=0
        local _cm _cm_manifest _pc_val
        local _pcap_plugins_root="${ZBUILD_PLUGINS_ROOT:-$_CYCLE_ORCH_ROOT/plugins}"
        _manifest_graph_ensure_yaml_get 2>/dev/null || true
        for _cm in "${_CYCLE_STAGES[@]}"; do
            _cm_manifest="$(manifest_graph_resolve_member "$_pcap_plugins_root" "$_cm" 2>/dev/null)" || continue
            _pc_val="$(yaml_get "$_cm_manifest" "capabilities.produces_commits" 2>/dev/null || true)"
            if [[ "$_pc_val" == "true" ]]; then
                _has_build_member=1
                break
            fi
        done
        local _no_committed_changes=0
        if [[ "$converged" -eq 0 && "$_has_build_member" -eq 1 \
              && "$_build_verdict" != "empty_diff" ]] \
           && _cycle_no_commits_ahead "$state_dir"; then
            _no_committed_changes=1
            converged=1  # suppress: an empty branch is not a clean resting point
            _cycle_emit "cycle.no_committed_changes.suppressed_convergence" \
                "iter=$iter" "build_verdict=$_build_verdict" \
                "reason=would_converge_with_zero_commits_ahead_of_baseline"
        fi

        # ADR-034 / #846: full-suite gate intercept. If convergence predicate
        # fired (converged=0) but the test stage ran in targeted mode, the
        # targeted result is insufficient: we need a full-suite confirmation.
        # Suppress convergence exactly once by setting converged=1 and arming
        # ZBUILD_TEST_FULL_SUITE_GATE for the next iter (via the pending flag).
        # Fail-safe: if we're already at max_iterations, we cannot add an extra
        # iter — let max_iterations fire naturally below instead of looping.
        if [[ "$converged" -eq 0 ]]; then
            local _gate_run_mode; _gate_run_mode="$(_cycle_read_test_run_mode "$state_dir")"
            if [[ "$_gate_run_mode" == "targeted" ]] \
               && ! _cycle_check_max_iterations "$iter" "$_CYCLE_MAX_ITER"; then
                converged=1  # suppress: full-suite confirmation still needed
                _full_suite_gate_pending=1
                _cycle_emit "cycle.test.full_suite_gate" \
                    "iter=$iter" "run_mode=targeted" \
                    "reason=targeted_pass_requires_full_suite_confirmation"
            fi
        fi

        # Record the history row FIRST — termination checks need durable data.
        _cycle_record_iter_outcome "$history_file" "$iter" \
            "$h_verdict" "$h_status" "$failure_count" || true

        # ADR-027 (Wave 17-B #703): abort_when predicate. If matched, the
        # cycle returns rc=6 (cycle_abort) which propagates through every
        # enclosing cycle to the runner via _zbuild_propagate_abort. Evaluated
        # AFTER exit_when so converged-via-exit_when takes priority on tie.
        # Wave 19-E (#737): defensive set +e dance around the abort_when call,
        # mirroring the symmetric guard around the exit_when predicate above.
        # The orchestrator runs with set +e internally so the bare call
        # should not trigger errexit, but symmetric handling eliminates a
        # class of fragility (e.g. set -e accidentally re-armed by an earlier
        # path that forgets the _ce sentinel). Dogfood 20260607140638-60666
        # exhibited the orchestrator emitting the abort_when predicate event
        # and then never reaching cycle.iteration.complete — symptoms
        # consistent with an unexpected errexit termination here.
        # The synthetic test in cycle-abort-when-no-match-converges-test.sh
        # locks the contract that abort_when-defined-but-not-matching
        # converges cleanly.
        local abort_matched=1
        local _aw_stage_var="_TPL_CYCLE_ABORT_WHEN_STAGE_${cycle_id//-/_}"
        if [[ -n "${!_aw_stage_var:-}" ]]; then
            local _ce2=0; case $- in *e*) _ce2=1 ;; esac
            set +e; _cycle_check_abort_when "$verdicts_blob"; abort_matched=$?
            [[ $_ce2 -eq 1 ]] && set -e
        fi

        # #840 (ADR-030): resolve any scope_expansion_request a member emitted
        # this iter. grant → wider write-scope for the next iter (cycle
        # continues); deny → blocked_on_scope terminal below (NO loop). Runs
        # AFTER converged/abort so a converged iter is never overridden, and
        # BEFORE max_iterations so a structurally-blocked build abandons in one
        # iter instead of grinding to max_iterations (the dogfood failure).
        local _scope_action="none"
        if [[ "$converged" -ne 0 ]]; then
            local _se=0; case $- in *e*) _se=1 ;; esac
            set +e; _scope_action="$(_cycle_resolve_scope_expansion "$cycle_id" "$state_dir")"; [[ $_se -eq 1 ]] && set -e
        fi

        # Decide overall status for the SINGLE atomic write (ADR-021: never
        # split state writes within an iter boundary).
        local overall_status="in_progress"
        local term_rc=-1
        local _term_member _term_reason
        # Call directly (not via $()) so the member id + reason globals survive
        # (a command-substitution subshell would drop them, #1220); stdout is
        # suppressed since the id is now read from the global.
        if _cycle_member_terminal_failure "$state_dir" >/dev/null; then
            # Phase 2 (ADR-021): a cycle member declared disposition=terminal in
            # its result artifact — outranks review.verdict==approve so the
            # member's contract is load-bearing and the pipeline halts (failed)
            # instead of converging to complete. recoverable (e.g. untagged_spec,
            # the #951 feedback loop) and advisory (infra flake) are NON-terminal.
            # GENERIC: the engine carries the member id, not any plugin identity.
            _term_member="$_CYCLE_TERMINAL_MEMBER_ID"
            # #1220: prefer the member's specific human reason (names SPEC ids +
            # violation class) over the opaque token; fall back when absent.
            _term_reason="${_CYCLE_TERMINAL_MEMBER_REASON:-}"
            _CYCLE_LAST_TERMINATED_REASON="${_term_reason:-member_terminal_failure}"
            overall_status="member_terminal_failure"; term_rc=8
            eb_emit_event "cycle.member.terminal_failure" \
                "cycle_id=$cycle_id" "member=$_term_member" \
                "reason=member_terminal_failure" \
                "detail=${_term_reason}" \
                2>/dev/null || true
        elif [[ "$converged" -eq 0 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="converged"
            overall_status="complete"; term_rc=0
        elif [[ "$abort_matched" -eq 0 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="cycle_abort"
            overall_status="cycle_abort"; term_rc=6
        elif [[ "$_scope_action" == "deny" ]]; then
            # #840: build needs out-of-scope files the policy won't grant (or
            # the cycle is not expandable). Abandon cleanly — never loop.
            _CYCLE_LAST_TERMINATED_REASON="blocked_on_scope"
            overall_status="blocked_on_scope"; term_rc=7
        elif _cycle_check_max_iterations "$iter" "$_CYCLE_MAX_ITER"; then
            # #1208 — THE single fatal condition: the cycle exhausted its
            # iteration budget WITHOUT a clean, passing convergence. Split
            # BY-SEVERITY using only GENERIC, repo-neutral signals (roster-driven
            # test verdict + failure_count — no plugin id / language / path /
            # test-format), so this works identically for an iOS/Swift, Go, or
            # Python target:
            #   tests FAILING (test.verdict==fail OR failure_count>0) → hard-fail
            #     term_rc=8 → runner status=failed, HALT (never ship an
            #     incomplete/failing tree — the #944 false-`complete` cure).
            #   tests PASSING but not cleanly converged → term_rc=2
            #     (unconverged→review; on_max is honored at the runner). Never a
            #     silent `complete` on an unfinished build (mid-flight suppression
            #     above already blocked that this iter).
            # (#1208 removed the early velocity_plateau / plateau / divergence
            # terminators and the #1117 empty-diff stall-break: the cycle runs ALL
            # its tries. Each attempt is cheap — the build self-yields on an empty
            # diff — and plateau signal now only classifies THIS exhaustion
            # outcome, it never stops the cycle early.)
            # "Tests failing" is the AUTHORITATIVE verifier signal of the `test`
            # member — and ONLY that member: (a) test.verdict==fail, OR (b) the
            # roster's test-results artifact reports a positive failed count. We
            # read `.failed` DIRECTLY from test-results.json (not the generic
            # failure_count), so a non-test gate flagging a NON-terminal condition
            # (acceptance untagged_spec / negctl-timeout infra, a non-blocking cq
            # member) can NEVER inflate a hard-fail. This closes a residual
            # false-fatal: the generic failure_count is contaminated by non-test
            # gate failures whenever the #511 Pin-10 test-results override did NOT
            # apply (results absent/malformed) — keying on the artifact avoids that
            # entirely. Results absent/malformed while tests pass → NOT a hard-fail
            # → rc=2 (unconverged->review). A cycle with no test-results cannot
            # assert test failure via clause (b). GENERIC: test-results.json is the
            # roster's test artifact (ADR-044 count contract feeds it) — no plugin
            # id / language / path assumption beyond the canonical `test` member.
            local _exh_test_verdict _exh_test_failed="" _exh_trj
            _exh_test_verdict="$(jq -r '.test.verdict // ""' <<< "$verdicts_blob" 2>/dev/null || true)"
            _exh_trj="$state_dir/artifacts/test-results.json"
            if [[ -s "$_exh_trj" ]]; then
                _exh_test_failed="$(jq -r '.failed // empty' "$_exh_trj" 2>/dev/null || true)"
            fi
            # #1261: reason-aware exhaustion (timeout-exhaustion exception to the
            # ADR-019 on_max=continue fall-through). When the TERMINATING iteration
            # was interrupted by a router timeout (a member surfaced the repo-neutral
            # did_not_finish verdict) AND the cycle has NO authoritative verifier
            # signal (no `test` member verdict AND no test-results.json), the final
            # artifact is the empty #945 timeout marker — there is nothing to
            # certify and nothing for a downstream stage to consume. Continuing
            # under on_max=continue would carry that empty artifact forward (design
            # → build implements from nothing, the #1261 bug). HALT with a distinct
            # terminal reason instead (rc=8 → runner status=failed). This is NOT
            # on_max:halt (too blunt — it would also hard-fail a genuine CONTENT
            # non-convergence): a content non-convergence has no did_not_finish tail
            # and keeps the ADR-019 continue below. GENERIC/repo-neutral: keys only
            # on the did_not_finish tail + absence of a test signal (NOT the stage
            # id) — build_test_cycle ALWAYS runs `test`, so it has a signal and is
            # unaffected (scope: design-only for now, #1261); a future verifier-less
            # cycle inherits the same fail-fast.
            if [[ "$_iter_did_not_finish" -eq 1 && -z "$_exh_test_verdict" && ! -s "$_exh_trj" ]]; then
                eb_emit_event "cycle.timeout_exhausted" \
                    "cycle_id=$cycle_id" "iter=$iter" \
                    "reason=design_timeout_exhausted" 2>/dev/null || true
                _CYCLE_LAST_TERMINATED_REASON="design_timeout_exhausted"
                overall_status="max_iterations"; term_rc=8
            elif [[ "$_exh_test_verdict" == "fail" ]] \
               || { [[ "$_exh_test_failed" =~ ^[0-9]+$ ]] && [[ "$_exh_test_failed" -gt 0 ]]; }; then
                _CYCLE_LAST_TERMINATED_REASON="max_iterations_tests_failing"
                overall_status="max_iterations"; term_rc=8
            else
                _CYCLE_LAST_TERMINATED_REASON="max_iterations"
                overall_status="max_iterations"; term_rc=2
            fi
        elif [[ "$_no_committed_changes" -eq 1 && "$_scope_action" != "grant" ]]; then
            # #1265: the iteration would have converged on ZERO committed changes
            # (a scope_violation discarded the diff, or nothing was ever committed)
            # and no governed scope grant is pending to let the next iter commit.
            # Halt terminally (rc=5 blocked-class → the pipeline stops before
            # review/pr; blocked never route_backs, see below) instead of shipping
            # an empty branch to a confusing `pr` abort. When _scope_action==grant
            # the #870/#840 expansion lets the next iter commit, so we do NOT
            # terminate (fall through to in_progress and iterate).
            _CYCLE_LAST_TERMINATED_REASON="no_committed_changes"
            overall_status="no_committed_changes"; term_rc=5
            _cycle_emit "cycle.no_committed_changes" \
                "iter=$iter" "build_verdict=$_build_verdict" \
                "reason=zero_commits_ahead_of_intake_baseline"
        elif _cycle_detect_blocked "$verdicts_blob" "$iter"; then
            # #528: structural cannot-progress class (raw verdict error/corrupt_diff/
            # block — NOT a timeout, which iterates). rc=5 halts the pipeline.
            # #1208: retained as the ONLY early terminator besides converge/abort/
            # scope-deny — genuine structural failures still halt fast.
            _CYCLE_LAST_TERMINATED_REASON="blocked"
            overall_status="blocked"; term_rc=5
        fi

        # #1217 (ADR-045): bounded typed backward-route. ONLY a CORRECTABLE
        # non-clean terminal (rc=2 unconverged / rc=8 member_terminal_failure)
        # may reroute — a clean converge (0), abort (6), blocked (5), scope-deny
        # (7), config (4) and signals (130/143) NEVER reroute. When the
        # route_back predicate matches, convert the terminal into rc=11
        # (route_back) and STASH the by-severity fallback rc + target as GLOBALS
        # (no `local`) so the runner can (a) rewind the dispatch index to the
        # target if budget remains, or (b) restore the fallback rc for the
        # normal by-severity terminal handling if budget is exhausted. Only the
        # runner owns dispatch-unit rewind; the orchestrator merely reclassifies.
        # #1261: a timeout-exhaustion (design_timeout_exhausted) is an INFRA
        # failure, never a correctable content terminal — it must NEVER reroute
        # (route_back exists to let build re-drive design on a CONTENT tautology).
        if [[ ( $term_rc -eq 2 || $term_rc -eq 8 ) \
              && "$_CYCLE_LAST_TERMINATED_REASON" != "design_timeout_exhausted" ]]; then
            local _rb_to_var="_TPL_CYCLE_ROUTE_BACK_TO_${cycle_id//-/_}"
            if [[ -n "${!_rb_to_var:-}" ]]; then
                local _rce=0; case $- in *e*) _rce=1 ;; esac
                local _rb_matched=1
                set +e; _cycle_check_route_back "$verdicts_blob"; _rb_matched=$?; [[ $_rce -eq 1 ]] && set -e
                if [[ $_rb_matched -eq 0 ]]; then
                    _CYCLE_ROUTE_BACK_FALLBACK_RC=$term_rc
                    # #1227: stash the ORIGINAL terminal reason alongside the
                    # fallback rc so the runner can restore it on the
                    # budget/cap-exhausted no-rewind path — otherwise the final
                    # cycle.complete/pipeline.end would misreport "route_back"
                    # instead of the real cause (e.g. the tautology message).
                    _CYCLE_ROUTE_BACK_FALLBACK_REASON="$_CYCLE_LAST_TERMINATED_REASON"
                    _CYCLE_ROUTE_BACK_TO="${!_rb_to_var}"
                    # #1225 (ADR-045): stash the id of the cycle that OWNS this
                    # edge so the runner keys the per-edge counter + declared max
                    # on the real edge. For a top-level cycle this equals the
                    # dispatch-unit id (byte-identical behavior); for a NESTED
                    # cycle it is the inner id, so the operator's inner `max` is
                    # honored instead of the outer unit's default.
                    _CYCLE_ROUTE_BACK_EDGE_ID="$cycle_id"
                    _CYCLE_LAST_TERMINATED_REASON="route_back"
                    overall_status="route_back"; term_rc=11
                fi
            fi
        fi

        # Single atomic state write per iter boundary.
        _cycle_state_write_iter_atomic "$state_file" "$cycle_id" "$iter" \
            "$h_verdict" "$h_status" "$failure_count" "$overall_status" || true

        # #1243/#1254: multi-axis health — code-change PROGRESS (this iter's
        # applied diff) combined with the DEFECT count into a single durable
        # SCORE. #1254 finished the rename: the misleading single-axis `velocity`
        # attribute is gone (no consumer read it); `progress`/`score` are the
        # multi-axis fields and the human-readable OUTPUT banner below shows the
        # calculation.
        local _ci_files _ci_add _ci_del
        read -r _ci_files _ci_add _ci_del <<< "$(_cycle_read_progress "$state_dir")"
        local _ci_progress=$(( _ci_add + _ci_del ))
        local _ci_score=$(( _ci_progress - failure_count ))
        eb_emit_event "cycle.iteration.complete" \
            "cycle_id=$cycle_id" "iter=$iter" "verdict=$h_verdict" \
            "failure_count=$failure_count" \
            "progress=$_ci_progress" \
            "score=$_ci_score" 2>/dev/null || true

        # #524 iter-complete hook — operator-visible iter trailer. Event emit
        # is durable above; the hook is best-effort (silent-failure mitigation
        # #1: event FIRST, banner SECOND). Runner registers this to call
        # _render_cycle_iter_complete with verdict / score / fc / elapsed.
        if declare -F cycle_iter_complete_hook >/dev/null 2>&1; then
            cycle_iter_complete_hook "$cycle_id" "$iter" "$h_verdict" \
                "$_ci_score" "$failure_count" || true
        fi

        # #833: cycle OUTPUT banner — termination-predicate eval + health score.
        # Event-FIRST (cycle.iteration.complete above), banner-SECOND ordering
        # is preserved. Pairs with the INPUT banner via _CYCLE_IO_SEQ[$iter].
        # kind=cycle keeps it fd-2 / stdout-only.
        if [[ -n "${_CYCLE_IO_SEQ[$iter]:-}" ]] && declare -F stage_io_end >/dev/null 2>&1; then
            local _cycle_out_body
            # #1243/#1241: plumb state_dir so the banner can compute the
            # multi-axis health score (artifacts/build-summary.json) and name
            # the failing gate(s) (artifacts/gate-aggregator-result.json).
            _cycle_out_body="$(_cycle_render_predicate_result "$iter" "$state_dir")"
            # #1253: when the full-suite gate suppressed convergence THIS iter
            # (a targeted pass held for full-suite confirmation, :2061-2071), the
            # banner above renders `MATCHED (got=pass)` from the RAW predicate yet
            # the cycle deliberately continues. Append a plain operator line so
            # the continue is explained, not a silent/confusing no-op. Pure
            # observability — control flow / convergence is unchanged; the pending
            # flag (set at :2066, consumed at the next iter's loop top) is 1 here
            # iff the gate fired this iter.
            if [[ "$_full_suite_gate_pending" -eq 1 ]]; then
                _cycle_out_body+=$'\ntargeted pass — running full suite to confirm before converging'
            fi
            # Suppress stdout only (stage_io_end prints nothing useful on fd 1);
            # do NOT redirect fd 2 — a `2>&1` here would swallow the OUTPUT
            # banner into /dev/null in production (#833 / PR #1039).
            stage_io_end --stage "$cycle_id" --kind cycle --seq "${_CYCLE_IO_SEQ[$iter]}" \
                --output "$_cycle_out_body" >/dev/null || true
        fi

        if [[ $term_rc -ge 0 ]]; then
            # #524 Pin 8: route ALL terminal-rc paths through
            # _cycle_handle_terminal_rc — single fan-in for cycle.complete
            # event + operator exit banner. The blocked diagnostic (cycle.blocked)
            # stays inline since it carries termination-specific evidence the
            # central helper doesn't know about.
            # #1208: the term_rc=2 (stalled/plateau) and term_rc=3 (divergence)
            # early terminators were removed — term_rc=2 now means only
            # "exhausted, tests passing → unconverged→review" (reason
            # max_iterations), which needs no extra diagnostic event beyond
            # cycle.complete. The plateau/velocity/divergence DETECTOR functions
            # remain defined (dormant, for reuse) but are no longer invoked.
            case "$term_rc" in
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
            { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return "$term_rc"; }
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
            { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 4; }
        fi
    done

    # Loop fell through without hitting max_iterations in the body — defensive
    _CYCLE_LAST_TERMINATED_REASON="max_iterations"
    _cycle_clear_traps
    { _CYCLE_TRAP_CYCLE_ID=''; [[ $_ORCH_HAD_E -eq 1 ]] && set -e; return 1; }
}
