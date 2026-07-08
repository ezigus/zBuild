#!/usr/bin/env bash
# core/pipeline/runner.sh — Pipeline orchestrator (issue #83, #208, #222, #225)
# ADR-001 (plugin contract), ADR-006 (resume contract), ADR-009 (platform-aware modularity),
# ADR-011 (pluggable orch backend)
set -euo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
# ADR-025 (Wave 15-B #684) abort-propagation helpers — sourced before any
# dispatch site can call them; idempotent source guard inside.
source "$_ZBUILD_ROOT/scripts/lib/abort-propagation.sh"
# #796 / ADR-021 v3 R1: pipeline final status helper honoring on_max=continue.
# shellcheck source=../../scripts/lib/runner-final-status.sh
source "$_ZBUILD_ROOT/scripts/lib/runner-final-status.sh"
source "$_ZBUILD_ROOT/core/output/stage-colors.sh"
source "$_ZBUILD_ROOT/core/state/atomic.sh"
source "$_ZBUILD_ROOT/core/state/resume.sh"
# #887: capture whether the operator PINNED any events location BEFORE
# event-bus.sh defaults them to $HOME/.zbuild/state — so per-run isolation
# overrides only the default, never an explicit operator/test override.
_ZBUILD_EVENTS_PINNED=""
[[ -n "${ZBUILD_EVENTS_DIR:-}${ZBUILD_EVENTS_JSONL:-}${ZBUILD_EVENTS_DB:-}" ]] && _ZBUILD_EVENTS_PINNED=1
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../config/config.sh
source "$_ZBUILD_ROOT/core/config/config.sh"
zbuild_config_init
# shellcheck source=../memory/contract.sh
source "$_ZBUILD_ROOT/core/memory/contract.sh"
memory_init || { echo "runner: memory backend failed to initialize" >&2; exit 2; }
source "$_ZBUILD_ROOT/core/detect/platforms.sh"
source "$_ZBUILD_ROOT/core/pipeline/template.sh"
source "$_ZBUILD_ROOT/core/pipeline/template-resolver.sh"
source "$_ZBUILD_ROOT/core/pipeline/resolver.sh"
# shellcheck source=../orch/contract.sh
source "$_ZBUILD_ROOT/core/orch/contract.sh"
# Strategy modules (ADR-009 §fanout/sequential/composite, issue #222)
source "$_ZBUILD_ROOT/core/pipeline/strategies/fanout.sh"
source "$_ZBUILD_ROOT/core/pipeline/strategies/sequential.sh"
source "$_ZBUILD_ROOT/core/pipeline/strategies/composite.sh"
# Runner helpers extracted from this file in #279 to keep it under the
# CLAUDE.md 500-line cap.
source "$_ZBUILD_ROOT/core/pipeline/dispatch.sh"
source "$_ZBUILD_ROOT/core/pipeline/contracts.sh"
source "$_ZBUILD_ROOT/core/pipeline/state_helpers.sh"
# ADR-020 (#496) pre-flight inter-stage data contract validator.
source "$_ZBUILD_ROOT/core/pipeline/contract-validator.sh"
# #507 verdict-driven stage-complete indicator (ADR-019 / ADR-020 amendment).
source "$_ZBUILD_ROOT/core/pipeline/verdict.sh"
# ADR-021 (#512) outer-cycle orchestrator (F1, flag-gated by ZBUILD_CYCLES_ENABLED).
source "$_ZBUILD_ROOT/core/pipeline/cycle-orchestrator.sh"
# ADR-039 (#1131) parallel stage-group executor (sibling of the cycle orchestrator).
source "$_ZBUILD_ROOT/core/pipeline/parallel-orchestrator.sh"

_usage() {
    # Usage shown on error or --help. Unix convention: stderr (#619).
    cat >&2 <<EOF
Usage: runner.sh --issue <N>|--goal "<text>" [--dry-run] [--template <id>]
                 [--resume] [--from-stage <stage>] [--no-resume] [--force]
  --issue <N>       GitHub issue number to work
  --goal "<text>"   Pipeline goal description (alternative to --issue)
  --dry-run         Print the stage plan without executing anything
  --template <id>   Pipeline template to use (default: simple)
  --resume          Resume an existing run (skip completed stages)
  --from-stage <s>  Skip ahead to stage <s> when resuming (emits warning)
  --no-resume       Force fresh start even if an in_progress state exists
  --force           Resume even if status=aborted
  --self-host       Dogfood zBuild's own engine: redirect read-only contract-
                    grammar libs to a working-tree snapshot (#963, ADR-023)

Environment:
  ZBUILD_PLATFORM_OVERRIDE  Force a single platform; detection short-circuits.
  ZBUILD_SCOPE_PATHS        Newline-delimited scope paths; written as '+ <path>' entries.
  ZBUILD_SELF_HOST          Set to 1 to enable self-host mode (same as --self-host).
  ZBUILD_CONTRACT_LIB_DIR   Override dir contract-reader stages source grammar libs from.
EOF
}

# Helpers extracted to dispatch.sh / contracts.sh / state_helpers.sh in #279:
#   _find_plugin_for_stage       → core/pipeline/dispatch.sh
#   _check_artifact_contract     → core/pipeline/contracts.sh
#   write_scope_override
#   _update_stage_status         } → core/pipeline/state_helpers.sh
#   _set_pipeline_status
#   (+ their _zbuild_runner_set_* jq filter helpers)

# Globals (not local) so EXIT trap can read them after main() returns.
_runner_run_id="" _runner_issue="" _runner_ended=false _runner_state_file=""

# ─── stage-start time cache (#508) ───────────────────────────────────────────
# Populated immediately before _render_stage_divider for each stage; read at
# the ✓/✗ complete/fail sites to compute the duration suffix. assoc array so
# nested / out-of-order stages (none today, but safe) still resolve correctly.
declare -gA _RUNNER_STAGE_START_MS=()

# ─── pipeline-wide start time cache (#525) ───────────────────────────────────
# Populated once at the top of main() right after _runner_run_id is sanitized
# (well before the EXIT trap installs) so every pipeline.end emit site — incl.
# preflight failure (L289) and the EXIT trap — can render a duration. Empty
# until set; readers degrade to "?s" on cache-miss (mirrors _runner_duration_token).
_RUNNER_PIPELINE_START_MS=""

# ─── _runner_now_ms (#508) ───────────────────────────────────────────────────
# Millisecond wall clock. Honors ZBUILD_STAGE_IO_NOW_MS_OVERRIDE so goldens
# can pin the timestamp (same env var as stage-io.sh — single test contract;
# do NOT introduce a runner-specific override name). Non-numeric override is
# treated as unset (defensive: a stray export shouldn't crash the runner).
# Empty stdout on failure → caller renders "??:??:?? UTC" / "?s" — no crash.
_runner_now_ms() {
    local ovr="${ZBUILD_STAGE_IO_NOW_MS_OVERRIDE:-}"
    if [[ -n "$ovr" && "$ovr" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ovr"
        return 0
    fi
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local us="${EPOCHREALTIME/./}"
        printf '%s' $(( 10#${us} / 1000 ))
        return 0
    fi
    printf '%s' "$(( ${EPOCHSECONDS:-$(date -u +%s)} * 1000 ))"
}

# ─── _runner_resolve_unit_index <to> (#1217, ADR-045) ────────────────────────
# Echo the index of <to> in _TPL_DISPATCH_UNITS[]: by direct unit id (stripping
# the stage:/cycle:/parallel: prefix) first, then by cycle/parallel MEMBERSHIP.
# Echo -1 if unresolved. Mirrors template.sh:_tpl_resolve_unit_index so the
# load-time route_back validator and this run-time rewind agree on ordering.
_runner_resolve_unit_index() {
    local _to="$1" _i _u _uid
    [[ -z "$_to" ]] && { echo "-1"; return 0; }
    for (( _i = 0; _i < ${#_TPL_DISPATCH_UNITS[@]}; _i++ )); do
        _u="${_TPL_DISPATCH_UNITS[_i]}"; _uid="${_u#*:}"
        [[ "$_uid" == "$_to" ]] && { echo "$_i"; return 0; }
    done
    for (( _i = 0; _i < ${#_TPL_DISPATCH_UNITS[@]}; _i++ )); do
        _u="${_TPL_DISPATCH_UNITS[_i]}"; _uid="${_u#*:}"
        local _safe="${_uid//-/_}"
        case "$_u" in
            cycle:*)
                local _mv="_TPL_CYCLE_STAGES_${_safe}"
                [[ ",${!_mv:-}," == *",$_to,"* ]] && { echo "$_i"; return 0; } ;;
            parallel:*)
                local _pv="_TPL_PARALLEL_FLOW_${_safe}"
                [[ ",${!_pv:-}," == *",$_to,"* ]] && { echo "$_i"; return 0; } ;;
        esac
    done
    echo "-1"
    return 0
}

# ─── _runner_now_short (#508) — HH:MM:SS UTC for stage banners ───────────────
# Returns ??:??:?? UTC when the underlying clock primitive yields nothing
# (defensive — the operator-visible banner still renders without crashing).
_runner_now_short() {
    local ms; ms="$(_runner_now_ms)"
    if [[ -z "$ms" || ! "$ms" =~ ^[0-9]+$ ]]; then
        printf '??:??:?? UTC'
        return 0
    fi
    local sec=$(( ms / 1000 ))
    local out
    out="$(date -u -r "$sec" +'%H:%M:%S UTC' 2>/dev/null \
        || date -u -d "@$sec" +'%H:%M:%S UTC' 2>/dev/null \
        || printf '??:??:?? UTC')"
    printf '%s' "$out"
}

# ─── _runner_duration_token <stage> (#508) ───────────────────────────────────
# Format the elapsed duration since the start cache was populated. Mirrors
# stage-io.sh::_stage_io_render_duration's "<N.N>s" for sub-minute durations;
# for >= 60 s we use "<m>m<ss>s" so a slow stage doesn't render as "127.4s".
# Cache miss → "?s" (no crash).
_runner_duration_token() {
    local stage="$1"
    local start="${_RUNNER_STAGE_START_MS[$stage]:-}"
    if [[ -z "$start" || ! "$start" =~ ^[0-9]+$ ]]; then
        printf '?s'
        return 0
    fi
    local now; now="$(_runner_now_ms)"
    if [[ -z "$now" || ! "$now" =~ ^[0-9]+$ ]]; then
        printf '?s'
        return 0
    fi
    local ms=$(( now - start ))
    (( ms < 0 )) && ms=0
    if (( ms < 60000 )); then
        awk -v m="$ms" 'BEGIN{printf "%.1fs", m/1000}'
    else
        local total_s=$(( ms / 1000 ))
        local mins=$(( total_s / 60 ))
        local secs=$(( total_s % 60 ))
        printf '%dm%02ds' "$mins" "$secs"
    fi
}

# ─── _runner_export_scope_allowlist <state_dir> (ADR-043) ────────────────────
# Redaction by construction: derive the per-run scope allowlist from plan.files[]
# and export it as ZBUILD_SCOPE_ALLOWLIST so route_to_model can redact without a
# plugin passing it. Called per-stage because plan.json only exists after the
# plan stage runs (empty before then — harmless, the scope manifest is the base
# allowlist and this value is purely ADDITIVE). Matches the extraction used by
# the design/build plugins.
_runner_export_scope_allowlist() {
    local state_dir="$1"
    local plan_json="$state_dir/artifacts/plan.json"
    local csv=""
    if [[ -f "$plan_json" ]]; then
        csv="$(jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
            "$plan_json" 2>/dev/null || echo "")"
    fi
    export ZBUILD_SCOPE_ALLOWLIST="$csv"
}

# ─── _runner_pipeline_duration_token (#525) ──────────────────────────────────
# Parallel to _runner_duration_token but for the pipeline-wide window. No stage
# argument — reads _RUNNER_PIPELINE_START_MS directly. Returns "?s" on cache
# miss so the banner still renders during very-early failures.
_runner_pipeline_duration_token() {
    local start="${_RUNNER_PIPELINE_START_MS:-}"
    if [[ -z "$start" || ! "$start" =~ ^[0-9]+$ ]]; then
        printf '?s'
        return 0
    fi
    local now; now="$(_runner_now_ms)"
    if [[ -z "$now" || ! "$now" =~ ^[0-9]+$ ]]; then
        printf '?s'
        return 0
    fi
    local ms=$(( now - start ))
    (( ms < 0 )) && ms=0
    if (( ms < 60000 )); then
        awk -v m="$ms" 'BEGIN{printf "%.1fs", m/1000}'
    else
        local total_s=$(( ms / 1000 ))
        local mins=$(( total_s / 60 ))
        local secs=$(( total_s % 60 ))
        printf '%dm%02ds' "$mins" "$secs"
    fi
}

# ─── _pipeline_status_glyph <status> (#525) ──────────────────────────────────
# Thin shim mapping the ADR-006 pipeline status enum to a verdict class glyph
# (delegates to verdict_glyph from core/pipeline/verdict.sh, #507). The
# pipeline status enum is distinct from plugin verdicts on purpose — this is
# a render-only mapping for the terminal banner, NOT an extension of the
# verdict table itself.
#
# Mapping:
#   complete (banner-only; persisted event payload still says "success")
#                                          → pass  → ✓
#   failed | interrupted | aborted         → fail  → ✗
#   preflight_failed                       → warn  → ⚠
#   anything else                          → ⚠ (defensive)
_pipeline_status_glyph() {
    local status="${1:-}"
    case "$status" in
        complete|success)              verdict_glyph "pass" ;;
        failed|interrupted|aborted)    verdict_glyph "fail" ;;
        preflight_failed)              verdict_glyph "warn" ;;
        *)                             printf '%s' "?" ;;
    esac
}

# ─── _pipeline_status_color <status> (#525) ──────────────────────────────────
# Companion to _pipeline_status_glyph; delegates to verdict_color so NO_COLOR
# behavior matches the per-stage indicator line exactly.
_pipeline_status_color() {
    local status="${1:-}"
    case "$status" in
        complete|success)              verdict_color "pass" ;;
        failed|interrupted|aborted)    verdict_color "fail" ;;
        preflight_failed)              verdict_color "warn" ;;
        *)                             printf '%s' "${YELLOW:-}" ;;
    esac
}

# ─── _render_pipeline_end <status> [stage] [rc] (#525) ───────────────────────
# Emits the terminal banner that closes a pipeline run, framed with ═ (U+2550)
# to distinguish the pipeline boundary from the stage divider (━) and stage-io
# banners (─). Two-line layout:
#
#   ════════════════ pipeline.end ════════════════ HH:MM:SS UTC
#   <glyph> Pipeline <status_word>: status=<X> run_id=<Y> issue=<N> (took <dur>)
#
# Frame bars colored BLUE (chrome). Glyph + leading status word inherit the
# verdict class color (foreground signal). Right-aligned timestamp via the
# same width math as _render_stage_divider — degrades to a symmetric divider
# (no timestamp) when mid_bar <= 2.
#
# Writes to fd 2 so it composes correctly with other operator lines (info /
# success / error) under the same output redirection rules. Banner is emitted
# AFTER the pipeline.end JSONL event so the durable event is fail-closed
# against banner-write failures.
_render_pipeline_end() {
    local status="${1:-unknown}"
    local stage_hint="${2:-}"
    local rc_hint="${3:-}"
    local run_id="${_runner_run_id:-?}"
    local issue="${_runner_issue:-?}"
    # Best-effort value gathering. Each `$(...)` here forks a helper that may
    # itself fork an external (awk in the duration token, date/tput in the
    # clock/width helpers). Most call sites invoke this banner DIRECTLY under the
    # runner's `set -e` (e.g. the cycle/stage abort + LLM/scope-abort paths) —
    # not wrapped in `|| true` — so a transient under-load fork failure in any
    # one of these bare assignments would trip errexit and abort the render
    # BEFORE the printf block, silently dropping the operator's terminal banner
    # mid-teardown. `|| fallback` neutralizes errexit at each assignment so the
    # banner is always emitted once the function is reached, on every call site.
    # (#1156)
    local dur; dur="$(_runner_pipeline_duration_token)" || dur='?s'
    local glyph; glyph="$(_pipeline_status_glyph "$status")" || glyph='✗'
    local color; color="$(_pipeline_status_color "$status")" || color=''
    local frame="${BLUE:-}"
    local ts; ts="$(_runner_now_short)" || ts='??:??:?? UTC'
    local width; width="$(_term_width)" || width=80

    # Map status → operator-friendly verb for line 2. Tracks event payload
    # verbatim so "status=<X>" agrees with the verb. ("success" in legacy
    # event payloads renders as "complete" — see ADR-015 §v5 amendment).
    local word
    case "$status" in
        success|complete)    word="complete" ;;
        failed)              word="failed" ;;
        interrupted)         word="interrupted" ;;
        aborted)             word="aborted" ;;
        preflight_failed)    word="preflight_failed" ;;
        *)                   word="$status" ;;
    esac

    local label=" pipeline.end "
    # Layout: <left_bar><label><mid_bar> <ts>
    local left_bar=$(( (width - ${#label} - ${#ts} - 1) / 2 ))
    local mid_bar=$(( width - left_bar - ${#label} - ${#ts} - 1 ))

    local detail_status="status=${status}"
    [[ -n "$stage_hint" ]] && detail_status+=" stage=${stage_hint}"
    [[ -n "$rc_hint"    ]] && detail_status+=" rc=${rc_hint}"

    if [[ "$mid_bar" -le 2 ]]; then
        # Degraded layout — drop timestamp from the header.
        local sides=$(( (width - ${#label}) / 2 ))
        [[ "$sides" -lt 2 ]] && sides=2
        local bar
        printf -v bar '%*s' "$sides" ''
        bar="${bar// /═}"
        {
            printf '\n'
            printf '%b%s%b%s%b%b%s%b\n' "$frame" "$bar" "${BOLD:-}" "$label" "${RESET:-}" "$frame" "$bar" "${RESET:-}"
            printf '%b%b%s%b Pipeline %s: %s run_id=%s issue=%s (took %s)\n' \
                "$color" "${BOLD:-}" "$glyph" "${RESET:-}" \
                "$word" "$detail_status" "$run_id" "$issue" "$dur"
        } >&2
        return 0
    fi

    local lbar rbar
    printf -v lbar '%*s' "$left_bar" ''; lbar="${lbar// /═}"
    printf -v rbar '%*s' "$mid_bar"  ''; rbar="${rbar// /═}"
    {
        printf '\n'
        printf '%b%s%b%s%b%b%s%b %s\n' \
            "$frame" "$lbar" "${BOLD:-}" "$label" "${RESET:-}" \
            "$frame" "$rbar" "${RESET:-}" "$ts"
        printf '%b%b%s%b Pipeline %s: %s run_id=%s issue=%s (took %s)\n' \
            "$color" "${BOLD:-}" "$glyph" "${RESET:-}" \
            "$word" "$detail_status" "$run_id" "$issue" "$dur"
    } >&2
}

# ─── _render_stage_divider <stage> (#492, ts: #508) ──────────────────────────
# Emits a blank line + a heavy horizontal rule (━ U+2501) with the stage name
# centered in stage-color, then another blank line — written to fd 2 so it
# survives the same redirection rules as ▸/✓/✗ info lines. Used on every
# stage transition (between eb_emit_event "stage.start" and "▸ Running stage")
# so the operator's eye finds the next stage boundary at a glance.
#
# #508: right-align an HH:MM:SS UTC timestamp on the divider, mirroring the
# stage-io banner header right-alignment (_stage_io_compose_banner). Width
# math (no bookend glyphs in this layout — just bars + label + sep + ts):
#   visible = left_bar + len(label) + mid_bar + 1 (space) + len(ts)
#   left_bar = (width - len(label) - len(ts) - 1) / 2
#   mid_bar  = width - left_bar - len(label) - len(ts) - 1
# Degrade rule: when mid_bar <= 2 (very narrow terminals) we drop the
# timestamp and emit the legacy symmetric divider so layout stays legible.
_render_stage_divider() {
    local stage="$1"
    local width
    width="$(_term_width)"
    local color
    color="$(_stage_color "$stage")"
    local label=" ${stage} "
    local ts; ts="$(_runner_now_short)"

    # Layout: <left_bar><label><mid_bar> <ts>
    # Visible width = left_bar + len(label) + mid_bar + 1 (sep) + len(ts).
    local left_bar=$(( (width - ${#label} - ${#ts} - 1) / 2 ))
    local mid_bar=$(( width - left_bar - ${#label} - ${#ts} - 1 ))

    if [[ "$mid_bar" -le 2 ]]; then
        # Degraded: legacy symmetric divider, no timestamp (narrow terminal).
        local sides=$(( (width - ${#label}) / 2 ))
        [[ "$sides" -lt 2 ]] && sides=2
        local bar
        printf -v bar '%*s' "$sides" ''
        bar="${bar// /━}"
        {
            printf '\n'
            printf '%b%s%b%s%b%b%s%b\n' "$color" "$bar" "${BOLD:-}" "$label" "${RESET:-}" "$color" "$bar" "${RESET:-}"
            printf '\n'
            # #523: trailing blank line — combined with the existing leading
            # \n above, produces two stacked blanks between consecutive stages.
            # Cycle sub-dividers (ADR-015 §v6) intentionally do NOT add this.
            printf '\n'
        } >&2
        return 0
    fi

    local lbar rbar
    printf -v lbar '%*s' "$left_bar" ''; lbar="${lbar// /━}"
    printf -v rbar '%*s' "$mid_bar"  ''; rbar="${rbar// /━}"
    {
        printf '\n'
        # %b on colored fragments so \033[...] resolves like echo -e elsewhere.
        # Timestamp is plain text outside color escapes — NO_COLOR keeps it.
        printf '%b%s%b%s%b%b%s%b %s\n' \
            "$color" "$lbar" "${BOLD:-}" "$label" "${RESET:-}" \
            "$color" "$rbar" "${RESET:-}" "$ts"
        printf '\n'
        # #523: trailing blank line — combined with the leading \n above,
        # produces two stacked blanks between consecutive stages. Cycle
        # sub-dividers (ADR-015 §v6) intentionally do NOT add this.
        printf '\n'
    } >&2
}

# ─── Cycle banner helpers (#524, ADR-015 §v6, ADR-021) ───────────────────────
# Operator-fd-2 chrome for outer cycles (ADR-021). These render a visual
# hierarchy that nests cleanly with the existing stage-transition divider
# (_render_stage_divider) so the operator can see cycle entry, per-iter
# boundaries, per-iter outcomes, and cycle exit in the scrollback.
#
# Glyph + color ladder (heaviest → lightest):
#   ━━━ (U+2501) stage transition   — BOLD BLUE (handled in _render_stage_divider)
#   ═══ (U+2550) cycle entry/exit   — LIGHT_BLUE
#   ─── (U+2500) cycle iter divider — CYAN
#
# Routing contract (silent-failure mitigations):
#   - All 4 helpers write to fd 2 ONLY. Hardcoded `>&2`. NEVER capture in $(…)
#     — output would vanish. Banner emit follows event emit (event=durable,
#     banner=best-effort).
#   - `{ ...; } >&2 2>/dev/null || true` is used so a broken stderr can never
#     abort the cycle. Each block is a single printf wrapped in the redirect
#     group so SIGINT during banner emit cannot race on partial writes.
#   - These banners are fd-2 ONLY and NEVER appear in the PR comment body
#     rendered by gh_comment. Operator chrome only.
#
# Determinism: honors ZBUILD_TERM_WIDTH_OVERRIDE + ZBUILD_STAGE_IO_NOW_MS_OVERRIDE
# via _term_width / _runner_now_short (same contract as _render_stage_divider).

# ─── _render_cycle_entry <cycle_id> <max> <stages_csv> ───────────────────────
# Heavy `═` LIGHT_BLUE divider + `▸ Entering cycle <id>` line + DIM trailer
# (max + stages). Emitted by the runner BEFORE cycle_orchestrator_run so the
# operator's eye finds the cycle boundary before the first iter divider.
_render_cycle_entry() {
    local cycle_id="$1" max="$2" stages_csv="${3:-}" description="${4:-}"
    local width; width="$(_term_width)"
    local label=" cycle: ${cycle_id} "
    local sides=$(( (width - ${#label}) / 2 ))
    [[ "$sides" -lt 2 ]] && sides=2
    local bar
    printf -v bar '%*s' "$sides" ''
    bar="${bar// /═}"
    {
        printf '\n'
        printf '%b%s%b%s%b%b%s%b\n' \
            "${LIGHT_BLUE:-}" "$bar" "${BOLD:-}" "$label" "${RESET:-}" \
            "${LIGHT_BLUE:-}" "$bar" "${RESET:-}"
        printf '%b%b▸%b Entering cycle: %b%b%s%b\n' \
            "${LIGHT_BLUE:-}" "${BOLD:-}" "${RESET:-}" \
            "${LIGHT_BLUE:-}" "${BOLD:-}" "$cycle_id" "${RESET:-}"
        # #831: operator-facing description on its own DIM line, between the
        # Entering-cycle headline and the (max_iterations=…) trailer. Skipped
        # entirely when description is empty so templates without it render
        # identically to the pre-#831 banner (golden tests stay valid).
        if [[ -n "$description" ]]; then
            printf '%b  %s%b\n' "${DIM:-}" "$description" "${RESET:-}"
        fi
        printf '%b  (max_iterations=%s · stages=%s)%b\n' \
            "${DIM:-}" "$max" "$stages_csv" "${RESET:-}"
        printf '\n'
    } >&2 2>/dev/null || true
}

# ─── _render_parallel_entry <group_id> <max_parallel> <members_csv> ──────────
# ADR-039 (#1131): clone of _render_cycle_entry for a parallel stage group.
# Heavy `═` LIGHT_BLUE divider + `▸ Entering parallel group <id>` line + DIM
# trailer (max_parallel + members). Emitted by the runner BEFORE
# parallel_group_run so the operator's eye finds the group boundary first.
_render_parallel_entry() {
    local group_id="$1" max="$2" members_csv="${3:-}"
    local width; width="$(_term_width)"
    local label=" parallel: ${group_id} "
    local sides=$(( (width - ${#label}) / 2 ))
    [[ "$sides" -lt 2 ]] && sides=2
    local bar
    printf -v bar '%*s' "$sides" ''
    bar="${bar// /═}"
    {
        printf '\n'
        printf '%b%s%b%s%b%b%s%b\n' \
            "${LIGHT_BLUE:-}" "$bar" "${BOLD:-}" "$label" "${RESET:-}" \
            "${LIGHT_BLUE:-}" "$bar" "${RESET:-}"
        printf '%b%b▸%b Entering parallel group: %b%b%s%b\n' \
            "${LIGHT_BLUE:-}" "${BOLD:-}" "${RESET:-}" \
            "${LIGHT_BLUE:-}" "${BOLD:-}" "$group_id" "${RESET:-}"
        printf '%b  (max_parallel=%s · members=%s)%b\n' \
            "${DIM:-}" "$max" "$members_csv" "${RESET:-}"
        printf '\n'
    } >&2 2>/dev/null || true
}

# ─── _render_parallel_group_complete <group_id> <member_count> <failure_count> ─
# Issue OUT (ADR-039): DIM trailer after a parallel group's per-member lines,
# mirroring _render_cycle_exit's role for cycles. e.g.
# `▸ review_lenses complete — 5 members, 0 blocking`.
_render_parallel_group_complete() {
    local group_id="$1" count="${2:-0}" fail="${3:-0}"
    {
        printf '%b▸ %s complete — %s members, %s blocking%b\n' \
            "${DIM:-}" "$group_id" "$count" "$fail" "${RESET:-}"
    } >&2 2>/dev/null || true
}

# ─── _render_cycle_iter_divider <cycle_id> <iter> <max> ───────────────────────
# Light `─` CYAN sub-divider for each iter boundary, e.g.
# `─── build_test_cycle iter 2/5 ─────`. When this cycle is nested inside
# another cycle the orchestrator has already set ZBUILD_SEQ_PREFIX (e.g.
# `4.1`) — surface it as a `[<prefix>]` prefix so operators can tell at a
# glance which outer iter this divider belongs to:
#   outer (no prefix): `─── build_review_cycle iter 1/2 ───`
#   inner (prefix set): `─── [4.1] build_test_cycle iter 1/3 ───`
# Reuses the seq-prefix machinery from Wave 19-B #718 / cycle-orchestrator.sh:888
# — no new plumbing, no hook-signature change. Emitted by the orchestrator's
# iter-begin hook BEFORE the first per-stage banner of the iter.
_render_cycle_iter_divider() {
    local cycle_id="$1" iter="$2" max="$3"
    local prefix="${ZBUILD_SEQ_PREFIX:-}"
    local label
    if [[ -n "$prefix" ]]; then
        label=" [${prefix}] ${cycle_id} iter ${iter}/${max} "
    else
        label=" ${cycle_id} iter ${iter}/${max} "
    fi
    local width; width="$(_term_width)"
    local sides=$(( (width - ${#label}) / 2 ))
    [[ "$sides" -lt 2 ]] && sides=2
    local bar
    printf -v bar '%*s' "$sides" ''
    bar="${bar// /─}"
    {
        printf '\n%b%s%b%s%b%b%s%b\n' \
            "${CYAN:-}" "$bar" "${BOLD:-}" "$label" "${RESET:-}" \
            "${CYAN:-}" "$bar" "${RESET:-}"
    } >&2 2>/dev/null || true
}

# ─── _render_cycle_iter_complete <iter> <verdict> <score> <fc> <elapsed_s> ──
# Per-iter DIM trailer line e.g. `↳ iter 2 complete: verdict=pass score=-1
# failure_count=1 elapsed=4s`. Emitted by the orchestrator's iter-complete
# hook AFTER the `cycle.iteration.complete` event is durable. #1254: the
# `score` axis (progress − defects) replaced the retired `velocity` label so
# the per-iter line matches the OUTPUT banner's health score.
_render_cycle_iter_complete() {
    local iter="$1" verdict="$2" score="$3" failure_count="$4" elapsed_s="$5"
    {
        printf '%b↳ iter %s complete: verdict=%s score=%s failure_count=%s elapsed=%ss%b\n' \
            "${DIM:-}" "$iter" "$verdict" "$score" "$failure_count" "$elapsed_s" "${RESET:-}"
    } >&2 2>/dev/null || true
}

# ─── _render_cycle_exit <cycle_id> <reason> <iter> <max> ──────────────────────
# Heavy `═` LIGHT_BLUE divider + verdict-glyph line mapping termination reason
# to glyph + color (see #524 spec).
#   converged       → ✓ GREEN+BOLD
#   max_iterations  → ✗ RED+BOLD
#   plateau         → ✗ RED+BOLD
#   divergence      → ✗ RED+BOLD
#   aborted         → ⚠ YELLOW+BOLD
#   verdict_missing → ⚠ YELLOW+BOLD
#   blocked         → ✗ RED+BOLD (sibling #528)
#   error/config_invalid → ✗ RED+BOLD
#   unknown (typo)  → ✗ RED+BOLD (fail loud)
# Emitted by the runner AFTER cycle_orchestrator_run via _cycle_handle_terminal_rc.
_render_cycle_exit() {
    local cycle_id="$1" reason="$2" iter="$3" max="$4"
    local glyph color text
    case "$reason" in
        converged)
            glyph="✓"; color="${GREEN:-}"
            text="Cycle ${cycle_id} converged in ${iter}/${max} iters"
            ;;
        max_iterations)
            glyph="✗"; color="${RED:-}"
            text="Cycle ${cycle_id} exhausted max_iterations (${iter}/${max})"
            ;;
        plateau)
            glyph="✗"; color="${RED:-}"
            text="Cycle ${cycle_id} halted: plateau"
            ;;
        divergence)
            glyph="✗"; color="${RED:-}"
            text="Cycle ${cycle_id} halted: divergence"
            ;;
        aborted)
            glyph="⚠"; color="${YELLOW:-}"
            text="Cycle ${cycle_id} aborted: ${reason}"
            ;;
        verdict_missing)
            glyph="⚠"; color="${YELLOW:-}"
            text="Cycle ${cycle_id} halted: verdict missing"
            ;;
        blocked)
            glyph="✗"; color="${RED:-}"
            text="Cycle ${cycle_id} halted: blocked"
            ;;
        blocked_on_scope)
            # #840: build needs out-of-scope files the policy won't grant.
            glyph="⚠"; color="${YELLOW:-}"
            text="Cycle ${cycle_id} halted: blocked on scope (needs files outside write-scope)"
            ;;
        error|config_invalid)
            glyph="✗"; color="${RED:-}"
            text="Cycle ${cycle_id} failed: ${reason}"
            ;;
        *)
            # Fail loud on typo — default RED ✗ so operators see unknown reasons.
            glyph="✗"; color="${RED:-}"
            text="Cycle ${cycle_id} halted: ${reason}"
            ;;
    esac
    local width; width="$(_term_width)"
    local label=" cycle: ${cycle_id} "
    local sides=$(( (width - ${#label}) / 2 ))
    [[ "$sides" -lt 2 ]] && sides=2
    local bar
    printf -v bar '%*s' "$sides" ''
    bar="${bar// /═}"
    {
        printf '\n'
        printf '%b%s%b%s%b%b%s%b\n' \
            "${LIGHT_BLUE:-}" "$bar" "${BOLD:-}" "$label" "${RESET:-}" \
            "${LIGHT_BLUE:-}" "$bar" "${RESET:-}"
        printf '%b%b%s%b %s\n' \
            "$color" "${BOLD:-}" "$glyph" "${RESET:-}" "$text"
        printf '\n'
    } >&2 2>/dev/null || true
}

# #963: snapshot the read-only acceptance-grammar libs into the run's state dir
# for self-host dogfooding, so contract-reader stages read the TARGET working
# tree's grammar while the installed engine tree stays immutable (ADR-023).
# Snapshotted ONCE per run: an already-populated snapshot is never re-copied, so
# a mid-run working-tree edit cannot mutate what the readers parse. merge-base.sh
# is a transitive dependency of the negctl/reachability libs (they source it from
# their own dir), so it is included to keep the snapshot a self-contained root.
_runner_snapshot_contract_libs() {
    local src_lib="$1" snapshot_dir="$2"
    [[ -z "$src_lib" || -z "$snapshot_dir" ]] && return 2
    # once-guard: a populated snapshot is authoritative for the whole run.
    [[ -f "$snapshot_dir/acceptance-block.sh" ]] && return 0
    mkdir -p "$snapshot_dir" || return 1
    local _lib
    for _lib in acceptance-block.sh acceptance-coverage.sh acceptance-negctl.sh \
                acceptance-reachability.sh merge-base.sh; do
        [[ -f "$src_lib/$_lib" ]] && cp "$src_lib/$_lib" "$snapshot_dir/$_lib"
    done
    return 0
}

# Remove a run's own event log + lock siblings so --no-resume starts from a
# clean, un-interleaved log (run_id reuse can leave a stale events.jsonl here).
_runner_reset_event_artifacts() {
    local dir="$1"
    [[ -z "$dir" ]] && return 0
    rm -f "$dir/events.jsonl" "$dir/events.jsonl.lock" \
          "$dir/events.db" "$dir/events.db.lock" 2>/dev/null || true
}

# Clear the shared global-default event log + stale lock files. Only ad-hoc /
# killed invocations write here (isolated engine runs use runs/<run_id>/), so a
# leftover events.jsonl.lock is never held by a live engine run — but a deferred
# TERM-trap can leave one behind, and a stale lock would make a later run's
# `flock -w` block. --no-resume clears it proactively at startup rather than
# relying on any exit-time trap (#run-hygiene, #887).
_runner_clear_stale_global_event_artifacts() {
    # #1127: honor the ZBUILD_STATE_ROOT indirection so a fenced nested run
    # (test stage) clears ITS root, never the parent's shared global default.
    local g="${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}"
    rm -f "$g/events.jsonl" "$g/events.jsonl.lock" \
          "$g/events.db" "$g/events.db.lock" 2>/dev/null || true
}

main() {
    local issue="" goal="" dry_run=false template="simple"
    local resume_mode=false from_stage="" no_resume=false force=false
    # #963: self-host mode — redirect read-only contract-grammar libs to a
    # working-tree snapshot. Honors ZBUILD_SELF_HOST=1 (resolved after parse).
    local self_host=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                [[ -z "${2:-}" ]] && { error "--issue requires a value"; _usage; return 2; }
                issue="$2"; shift 2 ;;
            --goal)
                [[ -z "${2:-}" ]] && { error "--goal requires a value"; _usage; return 2; }
                goal="$2"; shift 2 ;;
            --template)
                [[ -z "${2:-}" ]] && { error "--template requires a value"; _usage; return 2; }
                template="$2"; shift 2 ;;
            --dry-run)    dry_run=true;    shift ;;
            --resume)     resume_mode=true; shift ;;
            --no-resume)  no_resume=true;  shift ;;
            --force)      force=true;      shift ;;
            --self-host)  self_host=true;  shift ;;
            --from-stage)
                [[ -z "${2:-}" ]] && { error "--from-stage requires a value"; _usage; return 2; }
                from_stage="$2"; shift 2 ;;
            --help|-h)  _usage; return 0 ;;
            *) error "Unknown argument: $1"; _usage; return 2 ;;
        esac
    done

    # #963: ZBUILD_SELF_HOST=1 is equivalent to the --self-host flag.
    [[ "${ZBUILD_SELF_HOST:-0}" == "1" ]] && self_host=true

    if [[ -z "$issue" && -z "$goal" ]]; then
        error "Must specify --issue <N> or --goal \"<text>\""
        _usage
        return 2
    fi

    # --from-stage is only valid in resume mode
    if [[ -n "$from_stage" ]] && ! $resume_mode; then
        error "--from-stage is only valid with --resume"
        _usage
        return 2
    fi

    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"
    local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
    # #887: when neither ZBUILD_STATE_DIR nor ZBUILD_STATE_FILE is set, a fresh
    # run roots its state under runs/<run_id>/ so concurrent runs never share a
    # state dir / artifacts. Explicit overrides (tests, CLI resume) win and skip
    # the re-root. Resolved here; applied once run_id is known (fresh-start block).
    local _state_is_default=false
    [[ -z "${ZBUILD_STATE_DIR:-}" && -z "${ZBUILD_STATE_FILE:-}" ]] && _state_is_default=true
    local template_file
    # Per-repo overrides live under the target repo's working tree (#653/#724
    # Copilot finding): use $PWD, not $_ZBUILD_ROOT (the install tree).
    if ! template_file="$(resolve_template_file "$template" "$PWD" 2>&1)"; then
        error "$template_file"
        return 2
    fi

    # Cross-check: ZBUILD_STATE_FILE vs --issue (issue #296 Δ-4)
    # Placed before --dry-run so dry-run also surfaces mismatches.
    # Fail-closed on corrupt state files (rather than letting get_state_field
    # silently return its default and skip the check).
    if [[ -n "${ZBUILD_STATE_FILE:-}" && -n "$issue" && "$issue" != "0" \
          && -f "${ZBUILD_STATE_FILE}" ]]; then
        if ! jq empty "${ZBUILD_STATE_FILE}" >/dev/null 2>&1; then
            error "ZBUILD_STATE_FILE='${ZBUILD_STATE_FILE}' is not valid JSON; refusing to honor it alongside --issue $issue (fail-closed)"
            return 2
        fi
        local _existing_issue
        _existing_issue="$(jq -r '.issue // ""' "${ZBUILD_STATE_FILE}" 2>/dev/null || true)"
        if [[ -n "$_existing_issue" && "$_existing_issue" != "null" \
              && "$_existing_issue" != "0" && "$_existing_issue" != "$issue" ]]; then
            error "ZBUILD_STATE_FILE points at run for issue $_existing_issue but --issue is $issue (mismatch); aborting to avoid silent override"
            return 2
        fi
    fi

    # Load template, distinguishing "not found" from "found but invalid":
    #   - template FILE missing (resolve_template_file returns a non-existent
    #     path) → fall back to the built-in stage list (Test 11).
    #   - file EXISTS but load_template fails → a genuine config error, e.g. an
    #     invalid merge_policy enum (#1057 review): surface its stderr (no
    #     2>/dev/null) and abort, rather than masking it as "not found".
    #   - loads cleanly but defines no stages → built-in fallback.
    local active_stages=()
    if [[ ! -f "$template_file" ]]; then
        warn "Template '$template' not found; using built-in stage list"
        active_stages=(intake security-lens output)
    elif ! load_template "$template_file"; then
        error "Failed to load template '$template' (see error above); aborting"
        return 2
    elif [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then
        active_stages=("${_TPL_STAGES[@]}")
        info "merge_policy: ${_TPL_MERGE_POLICY:-auto_unless_flagged}"
    else
        warn "Template '$template' defines no stages; using built-in stage list"
        active_stages=(intake security-lens output)
    fi

    # ADR-020 (#496) pre-flight inter-stage data contract validator.
    # Runs BEFORE the --dry-run branch so dry-run also surfaces contract
    # violations. Default mode is `warn` for the first release; operators
    # opt into hard enforcement via ZBUILD_CONTRACT_VALIDATOR=enforce.
    # The validator returns 0 in warn mode regardless of violations and
    # 2 in enforce mode when at least one required input is unsatisfied.
    # Pre-flight state-file path defaults to the same target the runner
    # will later use; on enforce-failure the validator writes a minimal
    # state stub with status: preflight_failed (ADR-006 amendment).
    {
        local _cv_state_file_pf="${ZBUILD_STATE_FILE:-${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}/pipeline-state.json}"
        local _cv_stages_nl=""
        printf -v _cv_stages_nl '%s\n' "${active_stages[@]}"
        if ! _contract_validate_pipeline "$_cv_stages_nl" "$plugins_root" "$_cv_state_file_pf"; then
            error "Pre-flight contract validation failed (ZBUILD_CONTRACT_VALIDATOR=${ZBUILD_CONTRACT_VALIDATOR:-warn}). See above."
            # #525: pre-flight failure is a pipeline terminal — emit the
            # durable pipeline.end event FIRST (event-bus is fail-closed)
            # then the operator banner. run_id/issue may not yet be
            # established here; fall back to the CLI args / env / "-".
            _runner_run_id="${_runner_run_id:-${ZBUILD_RUN_ID:-preflight}}"
            _runner_issue="${_runner_issue:-${issue:-0}}"
            # Cache start time defensively so the duration token doesn't
            # render "?s" for preflight failures triggered very early.
            : "${_RUNNER_PIPELINE_START_MS:=$(_runner_now_ms)}"
            eb_emit_event "pipeline.end" "status=preflight_failed" \
                "run_id=$_runner_run_id" "issue=$_runner_issue" 2>/dev/null || true
            _render_pipeline_end "preflight_failed"
            return 2
        fi
    }

    if $dry_run; then
        info "Pipeline plan (dry-run, template=$template) — issue=${issue:-} goal=${goal:-}"
        local stage roles_out role plugin_dir pd
        for stage in "${active_stages[@]}"; do
            # Intentional fail-open (dry-run display only; missing template/plugin not fatal here)
            roles_out="$(template_stage_roles "$stage" 2>/dev/null || true)"
            if [[ -z "$roles_out" ]]; then
                # Intentional fail-open: dry-run lookup; empty result displayed as "(no plugin registered)"
                plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
                [[ -n "$plugin_dir" ]] \
                    && printf "  stage: %-20s → plugin: %s\n" "$stage" "$(basename "$plugin_dir")" \
                    || printf "  stage: %-20s → (no plugin registered)\n" "$stage"
            else
                while IFS= read -r role; do
                    [[ -z "$role" ]] && continue
                    # Intentional fail-open: dry-run role lookup; empty = display "(no plugin for role)"
                    pd="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
                    if [[ -z "$pd" ]]; then
                        # Role resolver found nothing; try direct ID match for display
                        # Intentional fail-open: display fallback only
                        pd="$(_find_plugin_for_stage "$stage" "$plugins_root" 2>/dev/null || true)"
                    fi
                    [[ -n "$pd" ]] \
                        && printf "  stage: %-20s role: %-20s → plugin: %s\n" "$stage" "$role" "$(basename "$pd")" \
                        || printf "  stage: %-20s role: %-20s → (no plugin for role)\n" "$stage" "$role"
                done <<< "$roles_out"
            fi
        done
        return 0
    fi

    mkdir -p "$state_dir"
    # Honor ZBUILD_STATE_FILE when set (e.g. by `pipeline resume --run-id`)
    # Cross-check vs --issue happened earlier (before --dry-run); see #296 Δ-4.
    local state_file
    if [[ -n "${ZBUILD_STATE_FILE:-}" ]]; then
        state_file="$ZBUILD_STATE_FILE"
        state_dir="$(dirname "$state_file")"
    else
        state_file="$state_dir/pipeline-state.json"
    fi
    _runner_state_file="$state_file"

    # Validate --from-stage against active_stages now that we have the stage list
    if [[ -n "$from_stage" ]]; then
        local _fs_valid=false _fs_s
        for _fs_s in "${active_stages[@]}"; do
            [[ "$_fs_s" == "$from_stage" ]] && { _fs_valid=true; break; }
        done
        if ! $_fs_valid; then
            error "--from-stage '$from_stage' is not a known stage (active stages: ${active_stages[*]})"
            return 2
        fi
        # #511 Pin 14: refuse --from-stage that lands INSIDE a cycle OR
        # AFTER a cycle (former case would silently skip cycle iters and
        # produce non-deterministic feedback state; latter would consume
        # stale test-results from a previous run). Mitigates silent-failure
        # finding #8. Walks the cycle stage lists collected by template.sh.
        local _r_cyc_count=0
        if declare -p _TPL_CYCLES >/dev/null 2>&1; then
            _r_cyc_count="${#_TPL_CYCLES[@]}"
        fi
        if [[ $_r_cyc_count -gt 0 ]]; then
            local _fs_cycle_id="" _cyc
            for _cyc in "${_TPL_CYCLES[@]}"; do
                local _safe="${_cyc//-/_}"
                local _stages_var="_TPL_CYCLE_STAGES_${_safe}"
                local _stages_csv="${!_stages_var:-}"
                local IFS_save="$IFS"; IFS=','
                # shellcheck disable=SC2206
                local -a _cs=($_stages_csv)
                IFS="$IFS_save"
                local _cs_s
                for _cs_s in "${_cs[@]}"; do
                    [[ "$_cs_s" == "$from_stage" ]] && { _fs_cycle_id="$_cyc"; break 2; }
                done
            done
            # Check "after a cycle" too — locate from_stage position and any
            # cycle position in active_stages, reject if any cycle position
            # is strictly less.
            local _after_cycle=0
            if [[ -z "$_fs_cycle_id" ]]; then
                local _fs_pos=-1 _i
                for _i in "${!active_stages[@]}"; do
                    [[ "${active_stages[$_i]}" == "$from_stage" ]] && _fs_pos=$_i && break
                done
                for _cyc in "${_TPL_CYCLES[@]}"; do
                    local _safe2="${_cyc//-/_}"
                    local _sv2="_TPL_CYCLE_STAGES_${_safe2}"
                    local _scsv2="${!_sv2:-}"
                    local _first_stage="${_scsv2%%,*}"
                    local _cpos=-1
                    for _i in "${!active_stages[@]}"; do
                        [[ "${active_stages[$_i]}" == "$_first_stage" ]] && _cpos=$_i && break
                    done
                    if [[ $_cpos -ge 0 && $_fs_pos -gt $_cpos ]]; then
                        _after_cycle=1; break
                    fi
                done
            fi
            if [[ -n "$_fs_cycle_id" || $_after_cycle -eq 1 ]]; then
                eb_emit_event "pipeline.from_stage.rejected" \
                    "reason=inside_cycle_or_after" "from_stage=$from_stage" \
                    "cycle_id=${_fs_cycle_id:-}" 2>/dev/null || true
                error "--from-stage '$from_stage' lands inside or after a cycle ('${_fs_cycle_id:-after-cycle}') — refused. Resume the cycle from its first stage or omit --from-stage."
                return 2
            fi
        fi
    fi

    # ── Resume / fresh-start policy ────────────────────────────────────────────
    if $resume_mode; then
        # Explicit --resume: check state exists and honour --force for aborted
        if [[ ! -f "$state_file" ]]; then
            error "No state file found at $state_file; cannot resume"
            return 1
        fi
        local existing_status
        existing_status="$(get_state_field "$state_file" '.status' '')"
        if [[ "$existing_status" == "aborted" ]] && ! $force; then
            error "Pipeline status is 'aborted'; use --force to resume anyway"
            return 1
        fi
        if [[ "$existing_status" == "complete" ]]; then
            warn "Pipeline status is 'complete'; starting fresh"
            resume_mode=false
        else
            # Restore run_id and issue from existing state
            _runner_run_id="$(get_state_field "$state_file" '.run_id' "$(date +%Y%m%d%H%M%S)-$$")"
            _runner_issue="$(get_state_field "$state_file" '.issue' '0')"
        fi
    elif ! $no_resume && [[ -f "$state_file" ]]; then
        # Auto-resume policy
        local recommendation
        recommendation="$(get_resume_recommendation "$state_file")"
        case "$recommendation" in
            auto_resume)
                info "Auto-resuming previous run (use --no-resume to force fresh start)"
                resume_mode=true
                _runner_run_id="$(get_state_field "$state_file" '.run_id' "$(date +%Y%m%d%H%M%S)-$$")"
                _runner_issue="$(get_state_field "$state_file" '.issue' '0')"
                ;;
            manual_resume_only)
                info "Previous run requires explicit --resume (or --force for aborted)"
                resume_mode=false
                ;;
            fresh_start|*)
                resume_mode=false
                ;;
        esac
    fi

    if ! $resume_mode; then
        # Sanitize ZBUILD_RUN_ID: strip characters unsafe in filenames (/, .., spaces, etc.)
        # to prevent path traversal when run_id is used in report-${run_id}.md filenames
        # AND in the per-run state dir below (#887). Generated BEFORE the re-root.
        local _raw_run_id="${ZBUILD_RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"
        _runner_run_id="${_raw_run_id//[^a-zA-Z0-9_.-]/}"
        # Fall back to generated ID if sanitization emptied the value
        [[ -z "$_runner_run_id" ]] && _runner_run_id="$(date +%Y%m%d%H%M%S)-$$"
        # #887: default state → isolate under runs/<run_id>/ so concurrent runs
        # never share artifacts. run_id is path-sanitized above. Done before
        # init_state so the per-run state file is the one created.
        if $_state_is_default; then
            state_dir="${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/runs/$_runner_run_id"
            mkdir -p "$state_dir"
            state_file="$state_dir/pipeline-state.json"
            _runner_state_file="$state_file"
        fi
        # --no-resume = explicit clean-slate. Rotate THIS run's own artifacts
        # (event log + locks in its state dir; may pre-exist when run_id is
        # reused) AND clear the stale shared global-default event log + lock
        # files. Ad-hoc/killed invocations leave those behind — a TERM-trap
        # deferred behind a foreground `wait` never removes the lock, so a
        # stale events.jsonl.lock could otherwise hang a later run's `flock -w`.
        # Clearing at STARTUP is the guarantee: it never depends on an
        # exit-time trap firing (#run-hygiene, #887).
        if $no_resume; then
            _runner_reset_event_artifacts "$state_dir"
            _runner_clear_stale_global_event_artifacts
        fi
        # Fresh start: clear any existing state at the (now per-run) path
        if [[ -f "$state_file" ]]; then
            rm -f "$state_file" "${state_file}.bak" "${state_file}.lock"
        fi
        _runner_issue="${issue:-0}"
        init_state "$state_file" "$_runner_run_id" "$_runner_issue"
        # Persist goal so resume can reconstruct the correct runner args.
        # Use jq --arg to safely encode user-supplied goal (prevents JSON injection
        # from embedded quotes or other special characters in the goal string).
        if [[ -n "${goal:-}" ]]; then
            set_state_field "$state_file" '.goal' "$(jq -n --arg g "$goal" '$g')"
        fi
    fi

    _runner_ended=false
    # #525: cache the pipeline-start wall clock NOW (right after _runner_run_id
    # is established but before any plugin runs) so every pipeline.end emit
    # site — including the EXIT trap — can render a duration.
    _RUNNER_PIPELINE_START_MS="$(_runner_now_ms)"
    export ZBUILD_RUN_ID="$_runner_run_id"
    export ZBUILD_ISSUE="$_runner_issue"
    export ZBUILD_GOAL="${goal:-}"
    # #618: child plugins (e.g. core/router/route.sh:route_to_model_loop, which
    # reads $ZBUILD_STATE_DIR/intake-baseline-ref.txt per #617) need to see
    # the resolved state_dir. Without this export the var is unset in plugin
    # subshells and the #617 BRANCH STATE block is silently skipped.
    export ZBUILD_STATE_DIR="$state_dir"
    # ADR-043 (redaction by construction): the router self-redacts when a stage
    # did not redact itself. Expose the fixed scope-manifest path to EVERY stage
    # (one place) so route_to_model can resolve the manifest without any plugin
    # passing it. The companion per-run allowlist (ZBUILD_SCOPE_ALLOWLIST, from
    # plan.files[]) is derived per-stage below via _runner_export_scope_allowlist,
    # because plan.json only exists after the plan stage runs.
    export ZBUILD_SCOPE_MANIFEST="$state_dir/scope-manifest.md"
    # #887: events must follow the (possibly per-run) state dir, else two runs'
    # events interleave in one events.jsonl. event-bus.sh defaults all three
    # vars to $HOME/.zbuild/state at SOURCE time, so for the per-run default we
    # must FORCE + export them (a plain :- would keep the stale flat value).
    # An explicit state dir respects whatever events location is already set.
    if [[ -z "$_ZBUILD_EVENTS_PINNED" ]]; then
        # Operator did NOT pin events → follow the resolved state dir. This
        # covers fresh per-run (state_dir=runs/<id>) AND resume (state_dir
        # re-derived from ZBUILD_STATE_FILE's dirname), so a resumed run's
        # events stay in its per-run dir instead of leaking to the flat default.
        export ZBUILD_EVENTS_DIR="$state_dir"
        export ZBUILD_EVENTS_JSONL="$state_dir/events.jsonl"
        export ZBUILD_EVENTS_DB="$state_dir/events.db"
    else
        # Operator pinned an events location → respect + export as-is.
        export ZBUILD_EVENTS_DIR ZBUILD_EVENTS_JSONL ZBUILD_EVENTS_DB
    fi
    # #887: latest-run pointer so `zbuild resume --latest` / `--attach` resolve
    # the most recent per-run dir without a scan. Only for the per-run default
    # (never pollute an explicit/test state dir). Atomic swap via ln -sfn.
    if [[ "$state_dir" == "${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/runs/"* ]]; then
        ln -sfn "$state_dir" "${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/latest" 2>/dev/null || true
    fi

    # #963: self-host — redirect the read-only acceptance-grammar libs that the
    # contract-reader stages (acceptance-gate, test_assessment, design) source to
    # a ONE-TIME snapshot of the TARGET working tree. This lets a dogfood of a
    # grammar-extending change read its OWN design with its OWN grammar, instead
    # of the installed (old) engine's reader mis-parsing it. Snapshotted into the
    # run's state dir so the installed engine tree stays immutable (ADR-023).
    # Non-self-host runs leave ZBUILD_CONTRACT_LIB_DIR unset → readers source from
    # the installed engine, unchanged.
    if $self_host; then
        local _wt_root _snap_dir
        _wt_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
        _snap_dir="$state_dir/contract-lib-snapshot"
        if _runner_snapshot_contract_libs "$_wt_root/scripts/lib" "$_snap_dir"; then
            export ZBUILD_CONTRACT_LIB_DIR="$_snap_dir"
            eb_emit_event "selfhost.contract_lib.snapshot" \
                "dir=$_snap_dir" "src=$_wt_root/scripts/lib" 2>/dev/null || true
        else
            warn "self-host: contract-lib snapshot failed; readers fall back to installed grammar"
        fi
    fi

    # Mark pipeline as in_progress
    _set_pipeline_status "$state_file" "in_progress"

    # Write user-provided scope paths to scope-override.md in '+ <path>' format.
    # After the intake stage completes, these entries are appended to scope-manifest.md
    # so intake's platform detection is preserved alongside the operator override.
    if [[ -n "${ZBUILD_SCOPE_PATHS:-}" ]]; then
        write_scope_override "$state_dir" "$_runner_run_id"
        info "Scope override paths written to $state_dir/scope-override.md"
    fi

    # #612: SIGINT marker — set by the INT trap so the EXIT trap can record
    # `pipeline.aborted reason=sigint` durably (the trap itself runs in the
    # signal handler context; we centralize the state/event writes in EXIT).
    # Wave 15-F (#686): _RUNNER_ABORT_REASON records which signal fired
    # (sigint|sigterm) so the EXIT trap can emit reason=sigint vs reason=sigterm.
    # _RUNNER_SIGINT_RECEIVED is preserved (set on either signal) for backward
    # compatibility with any consumer keying off the legacy marker.
    _RUNNER_SIGINT_RECEIVED=0
    _RUNNER_ABORT_REASON=""

    # Wave 15-H (#688): flag-gated bash job-control + process-group signal
    # forwarding. Default OFF — flag-off behavior is byte-identical to today.
    # When ZBUILD_RUNNER_JOB_CONTROL=1:
    #   - `set -m` enables job control so every backgrounded child gets its
    #     own PGID equal to its PID;
    #   - the SIGINT/TERM trap walks `jobs -p` and TERM-then-KILL's each
    #     PGID, reaping whole subtrees (not just direct PIDs).
    # This is belt-and-suspenders to the existing per-site kills:
    #   - Wave 8 (#612) per-PID kill in the build plugin,
    #   - Wave 15-G (#687) PG-kill in the router around `setsid -w` claude.
    # Both stay as fallback; Wave 15-H adds wider coverage for any future
    # backgrounded children of the runner shell. Safety considerations:
    #   - `jobs -p` is empty when no backgrounded children exist → trap loop
    #     is a safe no-op (no spurious kills).
    #   - `set -m` makes bash auto-disown completed children; the existing
    #     synchronous foreground dispatch path (plugin_hook_call subshells)
    #     is unaffected because `wait` semantics on direct foreground
    #     children are preserved.
    #   - The runner's own PGID becomes its session leader's PGID; the
    #     test harness's kernel-pgrp delivery still reaches it.
    if [[ "${ZBUILD_RUNNER_JOB_CONTROL:-0}" == "1" ]]; then
        set -m
    fi

    _runner_abort_trap() {
        # ADR-025 (Wave 15-B #684): the sentinel must be cleared on EVERY
        # exit path — clean end, normal failure, or abort — so a follow-on
        # zbuild invocation in the same state_dir never sees a stale
        # signal. Runs BEFORE the short-circuit because the
        # `_runner_ended=true` path is the common case (every successful
        # run hits it) and that path also needs the cleanup.
        _zbuild_disarm_abort_sentinel
        # Best-effort: drop THIS run's own lock siblings so a killed run does
        # not leave a stale .lock behind. flock releases on fd close at process
        # death regardless, but the on-disk lock FILE would otherwise linger;
        # this is belt-and-suspenders to the authoritative --no-resume startup
        # clear (the trap may be deferred behind a foreground `wait`, #run-hygiene).
        if [[ -n "${_runner_state_file:-}" ]]; then
            local _rd; _rd="$(dirname "$_runner_state_file")"
            rm -f "$_runner_state_file.lock" "$_rd/events.jsonl.lock" \
                  "$_rd/events.db.lock" 2>/dev/null || true
        fi
        [[ "$_runner_ended" == "true" ]] && return 0
        # Clean teardown (signal/OOM) → interrupted; operator cancel → aborted handled elsewhere.
        # Fail-closed: if we cannot mark the pipeline interrupted, emit an error event so the
        # operator can detect the unrecorded abort (was: || true, which silently dropped failures).
        if ! _set_pipeline_status "$_runner_state_file" "interrupted" 2>/dev/null; then
            eb_emit_event "pipeline.state.error" \
                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                "reason=abort_trap_set_status_failed" 2>/dev/null || true
        fi
        # #612: when the abort was caused by a signal, emit a distinguishable
        # `pipeline.aborted reason=<sigint|sigterm> status=interrupted` event so
        # the operator/postmortem can tell a Ctrl-C / kill from an OOM or fatal
        # stage rc. Always emit the legacy `pipeline.abort` too so existing
        # consumers don't break.
        # Wave 15-F (#686): reason carries the signal name (sigint|sigterm)
        # captured by _runner_signal_trap. Fall back to "sigint" for backward
        # compat if the marker is set but the reason was not recorded (a path
        # that should not occur but is cheap to guard).
        if [[ "${_RUNNER_SIGINT_RECEIVED:-0}" == "1" ]]; then
            eb_emit_event "pipeline.aborted" \
                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                "reason=${_RUNNER_ABORT_REASON:-sigint}" "status=interrupted" 2>/dev/null || true
        fi
        # Fail-closed: if abort event cannot be emitted, that is still non-fatal for the trap
        # itself (the process is exiting), but we do not silently swallow the failure.
        if ! eb_emit_event "pipeline.abort" \
            "run_id=$_runner_run_id" "issue=$_runner_issue" 2>/dev/null; then
            : # trap is exiting anyway; best-effort only
        fi
        # #525: terminal banner for the operator. Event already emitted above
        # so banner-render failure cannot lose the durable record. Reuses the
        # ✗ RED "aborted" rendering path (per ADR-015 §v5 amendment).
        # NB: do NOT redirect stderr away here — the banner writes to fd 2.
        # Wrap in a subshell so a non-zero rc inside doesn't abort the trap.
        ( _render_pipeline_end "aborted" ) || true
    }
    # #612 / Wave 15-F (#686): INT/TERM trap — flag the signal cause then
    # exit. Setting the marker + reason before exit lets the EXIT trap emit
    # `pipeline.aborted reason=<sigint|sigterm>`.
    # `exit 130` (SIGINT) or `exit 143` (SIGTERM) triggers _runner_abort_trap
    # (EXIT) which writes state + events.
    # ADR-025 (Wave 15-B #684): arm the cross-subshell abort sentinel FIRST so
    # any in-flight subshell (cycle iter, strategy fanout) sees the signal via
    # _zbuild_check_abort even if the abort rc has not yet propagated up to
    # them. Composition is additive — the existing `exit 130` body is preserved
    # and a parallel `exit 143` path is added for SIGTERM.
    _runner_signal_trap() {
        local _sig="${1:-INT}"
        _zbuild_arm_abort_sentinel
        _RUNNER_SIGINT_RECEIVED=1
        # Wave 15-H (#688): flag-gated process-group signal forwarding. When
        # `set -m` is on (via ZBUILD_RUNNER_JOB_CONTROL=1 at startup), every
        # child of this shell — backgrounded OR foreground subshell — has its
        # own PGID == its PID, so `kill -- -PID` reaches the whole subtree.
        # We enumerate direct children via two complementary sources:
        #   1. `jobs -p` — backgrounded jobs known to bash
        #   2. `pgrep -P $$` — all direct children, including foreground
        #      subshells bash does NOT list in `jobs -p`
        # We TERM each PGID, then schedule a 1s-grace KILL backstop for any
        # child that traps and ignores TERM. Per-site kills (Wave 8 build
        # plugin, Wave 15-G router) remain as fallback — this is belt-and-
        # suspenders, not replacement.
        #
        # Known limitation: bash defers signal-trap delivery until the
        # current foreground command returns. With `set -m`, a foreground
        # plugin subshell is in its own PGID, so a kernel-pgrp TERM to the
        # runner does NOT reach it directly; the trap fires only after the
        # subshell returns naturally. This is acceptable because:
        #   (a) the flag is OPT-IN (default OFF, byte-identical to today);
        #   (b) the router's Wave 15-G PG-kill already handles the slow
        #       claude-spawning path (the realistic blocker);
        #   (c) future waves will background plugin dispatch, at which
        #       point this trap loop becomes the primary kill path.
        if [[ "${ZBUILD_RUNNER_JOB_CONTROL:-0}" == "1" ]]; then
            local _child_pid _pgid _pgids_snapshot="" _self_pgid=""
            # Resolve the runner's own PGID so we never signal it (would
            # be suicide; the trap's `exit` below handles runner teardown).
            if command -v ps >/dev/null 2>&1; then
                _self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
            fi
            _w15h_collect_pgid() {
                # Resolve a child PID to its current PGID via `ps` (which
                # is reliable even when the PID is not the group leader)
                # and append it to the dedup snapshot. Falls back to the
                # PID itself when `ps` cannot resolve (e.g. child already
                # exited) — kill is best-effort 2>/dev/null anyway.
                local _pid="$1" _resolved=""
                [[ -z "$_pid" ]] && return 0
                if command -v ps >/dev/null 2>&1; then
                    _resolved="$(ps -o pgid= -p "$_pid" 2>/dev/null | tr -d ' ' || true)"
                fi
                [[ -z "$_resolved" ]] && _resolved="$_pid"
                # Skip runner's own PGID — protects against self-signal
                # when a child's PGID resolved to the runner's group
                # (can happen when `set -m` was not effective for that
                # spawn site, e.g. a sync call that pre-dated the flag).
                [[ -n "$_self_pgid" && "$_resolved" == "$_self_pgid" ]] && return 0
                case " $_pgids_snapshot " in *" $_resolved "*) return 0;; esac
                _pgids_snapshot+="$_resolved "
            }
            # Source 1: bash-tracked background jobs.
            while IFS= read -r _child_pid; do
                _w15h_collect_pgid "$_child_pid"
            done < <(jobs -p 2>/dev/null)
            # Source 2: all direct children (catches foreground subshells
            # which bash does NOT list in `jobs -p`).
            if command -v pgrep >/dev/null 2>&1; then
                while IFS= read -r _child_pid; do
                    _w15h_collect_pgid "$_child_pid"
                done < <(pgrep -P $$ 2>/dev/null)
            fi
            # TERM each unique resolved PGID.
            for _pgid in $_pgids_snapshot; do
                kill -TERM -- "-$_pgid" 2>/dev/null || true
            done
            if [[ -n "$_pgids_snapshot" ]]; then
                ( sleep 1
                  local _pg
                  for _pg in $_pgids_snapshot; do
                      kill -KILL -- "-$_pg" 2>/dev/null || true
                  done
                ) &
                disown $! 2>/dev/null || true
            fi
        fi
        case "$_sig" in
            TERM)
                _RUNNER_ABORT_REASON="sigterm"
                # Re-raise the standard 128+SIGTERM exit code so the parent
                # shell sees the cancellation, not a clean 0.
                exit 143
                ;;
            *)
                _RUNNER_ABORT_REASON="sigint"
                # Re-raise the standard 128+SIGINT exit code so the parent
                # shell sees the cancellation, not a clean 0.
                exit 130
                ;;
        esac
    }
    trap '_runner_abort_trap' EXIT
    # Wave 15-F (#686): TERM is now trapped with the same semantics as INT
    # (additive parity — SIGINT path is unchanged). The pre-15-F default
    # disposition for TERM (`kill mid-run emits pipeline.abort`) is preserved
    # by the EXIT trap, which still emits `pipeline.abort` after recording
    # `pipeline.aborted reason=sigterm`.
    trap '_runner_signal_trap INT' INT
    trap '_runner_signal_trap TERM' TERM

    # Detect platforms (writes state/platforms.json; returns "generic" if none found)
    local _DETECTED_PLATFORMS=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && _DETECTED_PLATFORMS+=("$p")
    done < <(detect_platforms "$PWD" "$state_dir" 2>/dev/null)
    [[ ${#_DETECTED_PLATFORMS[@]} -eq 0 ]] && _DETECTED_PLATFORMS=("generic")

    if $resume_mode; then
        # ADR-025 (Wave 15-E #685): defensive sentinel cleanup at resume entry.
        # The normal SIGINT path's EXIT trap already disarms the sentinel
        # in `_runner_abort_trap`, but a hard kill (-9), host crash, or any
        # path that skipped the EXIT trap can leave a stale .abort.signal.
        # Without this disarm the first `_zbuild_check_abort` pre-flight in
        # the dispatch loop would observe the stale sentinel and abort the
        # resumed run immediately. Resume must always start from a clean
        # signal channel.
        _zbuild_disarm_abort_sentinel
        eb_emit_event "pipeline.resume" "run_id=$_runner_run_id" "issue=$_runner_issue"
        info "Pipeline resuming — run_id=$_runner_run_id issue=${issue:-} goal=${goal:-} template=$template"
        if [[ -n "$from_stage" ]]; then
            warn "Skipping ahead to stage '$from_stage' as requested (--from-stage)"
            eb_emit_event "pipeline.skip_to_stage" "stage=$from_stage" "run_id=$_runner_run_id"
        fi
    else
        eb_emit_event "pipeline.start" "run_id=$_runner_run_id" "issue=$_runner_issue"
        info "Pipeline started — run_id=$_runner_run_id issue=${issue:-} goal=${goal:-} template=$template"
    fi

    # ── ADR-015 stage-io stdout channel ─────────────────────────────────────
    # Allocate a dedicated fd that survives plugin-side `2>/dev/null`
    # suppression. Plugins (intake, plan, etc.) call route_to_model or
    # run_captured_command with `2>/dev/null` to silence command noise; if the
    # stage-io banner were on fd 2 it would be silenced too. We open fd 3 to
    # the runner's stderr here, export ZBUILD_STAGE_IO_FD=3, and the
    # _stage_io_to_stdout renderer writes to that fd. The orch local engine's
    # `bash work-unit.sh > stdout 2> stderr` spawn touches only fd 1 and 2,
    # so fd 3 is inherited untouched by every plugin process.
    exec 3>&2
    export ZBUILD_STAGE_IO_FD=3

    # ── Determine skip-ahead point when --from-stage is set ───────────────────
    local skip_until_stage=""
    [[ -n "$from_stage" ]] && skip_until_stage="$from_stage"

    # ADR-021 (#512 + #511 F2): cycle-aware dispatch.
    # #511 Pin 4 — detect-and-enable with env override:
    #   ZBUILD_CYCLES_ENABLED=0  → disabled (force off, even if template asks)
    #   ZBUILD_CYCLES_ENABLED=1  → enabled (force on; explicit opt-in)
    #   unset + template has cycles[] → enabled (auto)
    #   else                       → disabled (no cycles in template anyway)
    # When auto-enabled, emit `cycle.auto_enabled` for observability.
    # When env=0 AND template has cycles, emit `cycle.disabled reason=env_override`
    # PLUS a stderr banner BEFORE the linear path runs (silent-failure #3).
    local _template_has_cycle=0 _u
    if [[ ${#_TPL_DISPATCH_UNITS[@]} -gt 0 ]]; then
        for _u in "${_TPL_DISPATCH_UNITS[@]}"; do
            [[ "$_u" == cycle:* ]] && _template_has_cycle=1 && break
        done
    fi
    local _cycles_enabled_raw="${ZBUILD_CYCLES_ENABLED:-}"
    local _has_cycle_unit=0
    case "$_cycles_enabled_raw" in
        0)
            _has_cycle_unit=0
            if [[ $_template_has_cycle -eq 1 ]]; then
                eb_emit_event "cycle.disabled" "reason=env_override" \
                    "template=$template" 2>/dev/null || true
                warn "Template '$template' declares cycles[] but ZBUILD_CYCLES_ENABLED=0 — running linear (env override)"
            fi
            ;;
        1)
            [[ $_template_has_cycle -eq 1 ]] && _has_cycle_unit=1
            ;;
        ""|*)
            if [[ $_template_has_cycle -eq 1 ]]; then
                _has_cycle_unit=1
                eb_emit_event "cycle.auto_enabled" "template=$template" \
                    "reason=template_declares_cycles" 2>/dev/null || true
            fi
            ;;
    esac

    # ADR-039 (#1131): a parallel group is a first-class dispatch unit — it is
    # NOT behind ZBUILD_CYCLES_ENABLED (that flag gates cycle convergence only).
    # Detect any parallel:<gid> unit so the cycle-aware dispatch loop runs even
    # for a template that has parallel groups but no cycles.
    local _template_has_parallel=0 _pu
    if [[ ${#_TPL_DISPATCH_UNITS[@]} -gt 0 ]]; then
        for _pu in "${_TPL_DISPATCH_UNITS[@]}"; do
            [[ "$_pu" == parallel:* ]] && _template_has_parallel=1 && break
        done
    fi
    # Enter the dispatch-unit loop when cycles are active OR the template has a
    # parallel group with no cycles. When cycles exist but are env-disabled, the
    # legacy linear path stays authoritative (parallel members then degrade to
    # sequential dispatch there) so the cycle env-override is never weakened.
    local _run_dispatch_units=0
    if [[ $_has_cycle_unit -eq 1 ]]; then
        _run_dispatch_units=1
    elif [[ $_template_has_parallel -eq 1 && $_template_has_cycle -eq 0 ]]; then
        _run_dispatch_units=1
    fi

    # cycle_dispatch_stage hook — F1 uses the same per-stage path that the
    # legacy stage loop uses. Returns the stage's rc; the orchestrator owns the
    # iteration semantics. Sets _CYCLE_DISPATCH_VERDICT / _CYCLE_DISPATCH_STATUS
    # so the orchestrator can score until/plateau/divergence.
    cycle_dispatch_stage() {
        local _cd_stage="$1" _cd_iter="$2" _cd_state="$3"
        _CYCLE_DISPATCH_VERDICT=""
        _CYCLE_DISPATCH_VERDICT_RAW=""
        _CYCLE_DISPATCH_STATUS=""
        _CYCLE_DISPATCH_REASON=""
        local _cd_plugin_dir _cd_rc=0
        # ADR-042: resolve role-then-id (uniform with leaf + parallel paths) so a
        # role-bound cycle member whose plugin id ≠ stage name resolves correctly.
        _cd_plugin_dir="$(resolve_stage_plugin "$_cd_stage" "$plugins_root" 2>/dev/null || true)"
        if [[ -z "$_cd_plugin_dir" ]]; then
            _CYCLE_DISPATCH_VERDICT="error"
            _CYCLE_DISPATCH_VERDICT_RAW="error"
            _CYCLE_DISPATCH_STATUS="failed"
            return 1
        fi
        set +e; plugin_hook_call "$_cd_plugin_dir" run "$_cd_stage" "$_cd_state"; _cd_rc=$?; set -e
        local _cd_manifest="$_cd_plugin_dir/manifest.yaml"
        # _CYCLE_DISPATCH_VERDICT holds the CLASSIFIED verdict (pass|warn|fail|
        # unknown + structural-failure pass-through) — used for .stage_verdicts
        # persistence (state_helpers.sh: verdict_class contract) and the
        # `stage.complete verdict=...` event emitted at runner.sh:1309 in the
        # `stage:*` dispatch branch. Mutating this to raw values like "approve"
        # would silently break the indicator-glyph + stage.verdicts contract.
        _CYCLE_DISPATCH_VERDICT="$(runner_read_stage_verdict "$state_dir" "$_cd_manifest" "$_cd_stage" "$_cd_rc" 2>/dev/null || echo "missing")"
        # Wave 19-A (#717): _CYCLE_DISPATCH_VERDICT_RAW is the parallel RAW
        # verdict (e.g. "approve", "request_changes", "block") consumed by the
        # cycle orchestrator's exit_when / abort_when / until predicates which
        # compare against the RAW template-declared value. Without this
        # separate channel, exit_when on review.verdict==approve never matches
        # (the classifier collapses approve→pass) and build_review_cycle runs to
        # max_iterations instead of converging cleanly (dogfood
        # 20260605055348-2232 symptom: pipeline ran ~10m, review approved,
        # then external interruption — but the cycle was structurally
        # unconvergeable regardless of the interrupt). Diagnostic events
        # (stage.verdict.missing, pipeline.indicator.unknown_verdict) are
        # emitted by the CLASSIFIED runner_read_stage_verdict call above —
        # the raw call here is side-effect-free and won't duplicate them.
        _CYCLE_DISPATCH_VERDICT_RAW="$(runner_read_stage_verdict_raw "$state_dir" "$_cd_manifest" "$_cd_stage" "$_cd_rc" 2>/dev/null || echo "missing")"
        [[ -z "$_CYCLE_DISPATCH_VERDICT_RAW" ]] && _CYCLE_DISPATCH_VERDICT_RAW="missing"
        # ADR-029 G2 (#810): expose the .reason channel when verdict=error so
        # the cycle orchestrator can distinguish router_timeout / router_oom_kill
        # (infra-failure → counts toward fast-abandon threshold) from other
        # error reasons (don't burn the abandon budget).
        _CYCLE_DISPATCH_REASON="$(runner_read_stage_reason "$state_dir" "$_cd_manifest" "$_cd_stage" "$_cd_rc" 2>/dev/null || echo "")"
        if [[ $_cd_rc -eq 0 ]]; then
            _CYCLE_DISPATCH_STATUS="complete"
        else
            _CYCLE_DISPATCH_STATUS="failed"
        fi
        return $_cd_rc
    }

    # ADR-039 (#1131): parallel-group member dispatch hook. Mirrors
    # cycle_dispatch_stage's plugin invocation + verdict readback, but publishes
    # the _PARALLEL_DISPATCH_* channel so it can run concurrently in a member
    # subshell without racing the cycle channel. The member subshell reads these
    # globals (they are subshell-local copies — no cross-member contention) and
    # writes its private per-slot sidecars; the parent never reads this channel.
    parallel_dispatch_stage() {
        local _pd_stage="$1" _pd_state="$2"
        _PARALLEL_DISPATCH_VERDICT=""
        _PARALLEL_DISPATCH_VERDICT_RAW=""
        _PARALLEL_DISPATCH_STATUS=""
        _PARALLEL_DISPATCH_REASON=""
        local _pd_plugin_dir _pd_rc=0
        # ADR-042: resolve role-then-id (uniform with leaf + cycle paths) so a
        # role-bound parallel member whose plugin id ≠ stage name resolves (e.g.
        # every lens-* member binds role review_lens → plugins/agent/review-lens).
        _pd_plugin_dir="$(resolve_stage_plugin "$_pd_stage" "$plugins_root" 2>/dev/null || true)"
        if [[ -z "$_pd_plugin_dir" ]]; then
            _PARALLEL_DISPATCH_VERDICT="error"
            _PARALLEL_DISPATCH_VERDICT_RAW="error"
            _PARALLEL_DISPATCH_STATUS="failed"
            return 1
        fi
        set +e; plugin_hook_call "$_pd_plugin_dir" run "$_pd_stage" "$_pd_state"; _pd_rc=$?; set -e
        local _pd_manifest="$_pd_plugin_dir/manifest.yaml"
        # CLASSIFIED verdict (pass|warn|fail|…) — authoritative for the
        # .stage_verdicts contract + indicator glyph, recorded by the parent.
        _PARALLEL_DISPATCH_VERDICT="$(runner_read_stage_verdict "$state_dir" "$_pd_manifest" "$_pd_stage" "$_pd_rc" 2>/dev/null || echo "missing")"
        # RAW verdict computed for the future aggregator (ADR-039 §4 group-verdict
        # collapse, a later issue); kept on its own channel so the predicate path
        # can consume the template-declared value verbatim, mirroring the cycle.
        _PARALLEL_DISPATCH_VERDICT_RAW="$(runner_read_stage_verdict_raw "$state_dir" "$_pd_manifest" "$_pd_stage" "$_pd_rc" 2>/dev/null || echo "missing")"
        [[ -z "$_PARALLEL_DISPATCH_VERDICT_RAW" ]] && _PARALLEL_DISPATCH_VERDICT_RAW="missing"
        _PARALLEL_DISPATCH_REASON="$(runner_read_stage_reason "$state_dir" "$_pd_manifest" "$_pd_stage" "$_pd_rc" 2>/dev/null || echo "")"
        if [[ $_pd_rc -eq 0 ]]; then
            _PARALLEL_DISPATCH_STATUS="complete"
        else
            _PARALLEL_DISPATCH_STATUS="failed"
        fi
        return $_pd_rc
    }

    # #524: register cycle banner hooks. The orchestrator calls these (when
    # declared) at iter-begin, iter-complete, and exit. Definitions are local
    # to the runner so the orchestrator stays event-emit + control-flow only
    # (no terminal rendering coupling).
    cycle_iter_begin_hook() {
        local _h_cycle_id="$1" _h_iter="$2" _h_max="$3"
        _CYCLE_ITER_START_MS[$_h_iter]="$(_runner_now_ms)"
        _render_cycle_iter_divider "$_h_cycle_id" "$_h_iter" "$_h_max"
    }
    cycle_iter_complete_hook() {
        local _h_cycle_id="$1" _h_iter="$2" _h_verdict="$3" \
              _h_score="$4" _h_fc="$5"
        local _h_start="${_CYCLE_ITER_START_MS[$_h_iter]:-}"
        local _h_elapsed=0
        if [[ -n "$_h_start" && "$_h_start" =~ ^[0-9]+$ ]]; then
            local _h_now; _h_now="$(_runner_now_ms)"
            if [[ "$_h_now" =~ ^[0-9]+$ ]]; then
                _h_elapsed=$(( (_h_now - _h_start) / 1000 ))
                (( _h_elapsed < 0 )) && _h_elapsed=0
            fi
        fi
        _render_cycle_iter_complete "$_h_iter" "$_h_verdict" \
            "$_h_score" "$_h_fc" "$_h_elapsed"
    }
    cycle_exit_hook() {
        local _h_cycle_id="$1" _h_reason="$2" _h_iter="$3" _h_max="$4"
        _render_cycle_exit "$_h_cycle_id" "$_h_reason" "$_h_iter" "$_h_max"
    }

    # Issue OUT (ADR-039): per-member completion render hook — the parallel
    # sibling of cycle_iter_complete_hook. parallel-orchestrator.sh calls it (when
    # declared) once per member in the parent post-join loop (declaration order,
    # parent-serial → no subshell stdout interleave). Members are file-only (io:
    # [file]), so instead of streaming raw JSON each lens prints ONE
    # human-readable line. Resolves the shared artifact dir from main()'s
    # state_dir (dynamic scope at the orchestrator call site).
    parallel_member_complete_hook() {
        local _h_group="$1" _h_member="$2" _h_slot="$3" \
              _h_rc="$4" _h_verdict="$5" _h_status="$6"
        render_parallel_member_line "$_h_member" "${state_dir}/artifacts" \
            "$_h_rc" "$_h_verdict" "$_h_status"
    }
    parallel_group_complete_hook() {
        local _h_group="$1" _h_count="$2" _h_fail="$3"
        _render_parallel_group_complete "$_h_group" "$_h_count" "$_h_fail"
    }

    if [[ $_run_dispatch_units -eq 1 ]]; then
        local _unit _rc=0
        # #527: track non-zero cycle terminations across the dispatch loop so the
        # final pipeline_status write below reflects unconverged outcomes as
        # `failed` instead of silently overwriting them with `complete`.
        # rc∈{1,2,3} (max_iter/plateau/divergence) → cycle continued to review;
        # ADR-019 fail-closed coercion (#485) must remain authoritative, but the
        # pipeline-level status must also reflect the cycle's non-convergence.
        local _RUNNER_CYCLE_UNCONVERGED=0
        local _RUNNER_CYCLE_UNCONVERGED_REASON=""
        local _RUNNER_CYCLE_UNCONVERGED_ID=""
        # #796 / ADR-021 v3 R1: capture on_max value of the unconverged cycle
        # so the final-status aggregator can honor on_max=continue.
        local _RUNNER_CYCLE_UNCONVERGED_ON_MAX=""
        # #1217 (ADR-045): GLOBAL bounded backward-route budget. The count is the
        # TOTAL number of forward passes over the routed segment across the WHOLE
        # run; the initial forward pass counts as 1, so the default of 2 permits
        # EXACTLY one jump back. Config-overridable (repo-agnostic) via
        # ZBUILD_ROUTE_BACK_BUDGET. This global total is the HARD ceiling; each
        # edge's own `max` is a subordinate local cap enforced below.
        local _RUNNER_ROUTE_BACK_BUDGET="${ZBUILD_ROUTE_BACK_BUDGET:-2}"
        [[ "$_RUNNER_ROUTE_BACK_BUDGET" =~ ^[0-9]+$ ]] || _RUNNER_ROUTE_BACK_BUDGET=2
        # #1227: clamp to >=1. A budget of 0 gives a confusing "pass 1/0" and
        # silently disables route_back; the initial forward pass always counts as 1.
        if (( _RUNNER_ROUTE_BACK_BUDGET < 1 )); then _RUNNER_ROUTE_BACK_BUDGET=1; fi
        local _RUNNER_ROUTE_BACK_PASSES=1
        # #682 (Wave 15-D): cardinal counter for the cycle-aware dispatch loop.
        # Each unit (stage OR cycle) occupies ONE cardinal slot — cycles render
        # internal `<iter>.<position>` labels via the orchestrator while linear
        # stages render the cardinal directly via ZBUILD_STAGE_IO_SEQ_LABEL.
        local _runner_cardinal=0
        # #1217 (ADR-045): INDEX-form loop so rc=11 (route_back) can rewind _ui to
        # a strictly-earlier dispatch unit and replay forward (see the rc=11
        # branch in the cycle arm). Forward-only when no cycle ever returns 11.
        local _ui
        for (( _ui = 0; _ui < ${#_TPL_DISPATCH_UNITS[@]}; _ui++ )); do
            _unit="${_TPL_DISPATCH_UNITS[_ui]}"
            _runner_cardinal=$(( _runner_cardinal + 1 ))
            case "$_unit" in
                cycle:*)
                    local _cyc_id="${_unit#cycle:}"
                    # #524: replace bare `info` with operator-visible cycle
                    # entry banner (heavy ═ + ▸ Entering + DIM trailer).
                    local _cyc_stages_csv=""
                    local _cyc_safe="${_cyc_id//-/_}"
                    local _cyc_stages_var="_TPL_CYCLE_STAGES_${_cyc_safe}"
                    local _cyc_max_var="_TPL_CYCLE_MAX_${_cyc_safe}"
                    _cyc_stages_csv="${!_cyc_stages_var:-}"
                    local _cyc_max="${!_cyc_max_var:-?}"
                    # #831: pass the optional operator-facing description so
                    # the banner can include it (renderer no-op when empty).
                    local _cyc_desc_var="_TPL_CYCLE_DESCRIPTION_${_cyc_safe}"
                    local _cyc_desc="${!_cyc_desc_var:-}"
                    _render_cycle_entry "$_cyc_id" "$_cyc_max" "$_cyc_stages_csv" "$_cyc_desc"
                    # #698 (Wave 16-A) → Wave 19-B (#718): publish the cycle's
                    # seq-prefix (= its pipeline-cardinal at top level) so the
                    # orchestrator can render N-level member labels via
                    # recursive prefix accumulation
                    # ("<prefix>.<iter>.<position>"). Single-cycle templates
                    # bottom out at 3 segments (prefix=cardinal). Nested cycles
                    # extend the prefix recursively (see cycle-orchestrator.sh
                    # cycle-as-member branch). Unset after the call so the var
                    # never leaks into the next dispatch unit.
                    export ZBUILD_SEQ_PREFIX="$_runner_cardinal"
                    # ADR-021 + #766: cycle_orchestrator_run may return rc∈{1,2,3}
                    # for soft termination (max_iterations/plateau/divergence).
                    # A bare function-call statement whose return value is non-zero
                    # under `set -e` causes the runner shell to exit, bypassing the
                    # rc-table branches below. Wrap the call in `&& _rc=0 || _rc=$?`
                    # so the rc is captured without tripping set -e. (The earlier
                    # `set +e` + post-restore pattern was fragile because callees
                    # could re-enable set -e mid-stream — observed in run_id
                    # 20260608223447-42915 where pipeline.abort fired between
                    # cycle.complete and where cycle.unconverged should have emitted.)
                    cycle_orchestrator_run "$_cyc_id" "$state_dir" "$state_file" && _rc=0 || _rc=$?
                    unset ZBUILD_SEQ_PREFIX
                    # #1217 (ADR-045): rc=11 = route_back — a CONTINUE-with-bounded-
                    # rewind class (NOT a halt; deliberately absent from the halt-case
                    # below). Resolve the stashed target to a dispatch-unit index; if
                    # it is STRICTLY earlier AND both the global budget and this edge's
                    # own `max` cap remain, emit cycle.route_back, rewind _ui and replay
                    # forward. Otherwise restore the by-severity fallback rc and fall
                    # through to the normal terminal handling below (NO rewind).
                    if [[ $_rc -eq 11 ]]; then
                        local _rb_tgt _rb_edge_safe _rb_edge_var _rb_edge_count _rb_edge_max_var _rb_edge_max
                        _rb_tgt="$(_runner_resolve_unit_index "${_CYCLE_ROUTE_BACK_TO:-}")"
                        # #1225 (ADR-045): key the per-edge counter + declared max
                        # on the cycle that OWNS the edge, not the top-level
                        # dispatch unit. For a top-level route_back the owner IS
                        # the dispatch unit (_CYCLE_ROUTE_BACK_EDGE_ID==_cyc_id) →
                        # byte-identical. For a NESTED cycle the inner id keys the
                        # inner's declared `max`; without it the outer unit's empty
                        # var defaulted to 2, silently ignoring the operator.
                        _rb_edge_safe="${_CYCLE_ROUTE_BACK_EDGE_ID:-$_cyc_id}"
                        _rb_edge_safe="${_rb_edge_safe//-/_}"
                        _rb_edge_var="_RUNNER_ROUTE_BACK_EDGE_${_rb_edge_safe}"
                        _rb_edge_count="${!_rb_edge_var:-0}"
                        _rb_edge_max_var="_TPL_CYCLE_ROUTE_BACK_MAX_${_rb_edge_safe}"
                        _rb_edge_max="${!_rb_edge_max_var:-2}"
                        [[ "$_rb_edge_max" =~ ^[1-9][0-9]*$ ]] || _rb_edge_max=2
                        if [[ "$_rb_tgt" -ge 0 && "$_rb_tgt" -lt "$_ui" \
                              && "$_RUNNER_ROUTE_BACK_PASSES" -lt "$_RUNNER_ROUTE_BACK_BUDGET" \
                              && "$_rb_edge_count" -lt "$_rb_edge_max" ]]; then
                            eb_emit_event "cycle.route_back" "cycle_id=$_cyc_id" \
                                "target=${_CYCLE_ROUTE_BACK_TO}" "reason=route_back" \
                                "pass=$_RUNNER_ROUTE_BACK_PASSES" \
                                "budget=$_RUNNER_ROUTE_BACK_BUDGET" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                2>/dev/null || true
                            _RUNNER_ROUTE_BACK_PASSES=$(( _RUNNER_ROUTE_BACK_PASSES + 1 ))
                            printf -v "$_rb_edge_var" '%s' "$(( _rb_edge_count + 1 ))"
                            warn "Cycle $_cyc_id route_back → '${_CYCLE_ROUTE_BACK_TO}' (pass $_RUNNER_ROUTE_BACK_PASSES/$_RUNNER_ROUTE_BACK_BUDGET); replaying forward"
                            # #1217 review fix (SHOULD-FIX): the routed segment
                            # [target..here] will replay. If a cycle IN that
                            # segment was flagged unconverged, discard the stale
                            # flag now so the replay's outcome is authoritative
                            # (prevents a false-fail after a successful
                            # correction). Scoped to the segment so an
                            # unconverged cycle BEFORE the target (not replayed)
                            # is never masked.
                            if [[ "${_RUNNER_CYCLE_UNCONVERGED:-0}" -eq 1 && -n "${_RUNNER_CYCLE_UNCONVERGED_ID:-}" ]]; then
                                local _rb_unconv_idx
                                _rb_unconv_idx="$(_runner_resolve_unit_index "$_RUNNER_CYCLE_UNCONVERGED_ID")"
                                if [[ "$_rb_unconv_idx" -ge "$_rb_tgt" ]]; then
                                    _RUNNER_CYCLE_UNCONVERGED=0
                                    _RUNNER_CYCLE_UNCONVERGED_REASON=""
                                    _RUNNER_CYCLE_UNCONVERGED_ID=""
                                    _RUNNER_CYCLE_UNCONVERGED_ON_MAX=""
                                fi
                            fi
                            _ui=$(( _rb_tgt - 1 ))
                            continue
                        fi
                        # Budget/edge-cap exhausted OR unresolved/forward target →
                        # restore the fallback rc and fall through (NO rewind).
                        _rc="${_CYCLE_ROUTE_BACK_FALLBACK_RC:-2}"
                        # #1227: also restore the ORIGINAL terminal reason the
                        # orchestrator stashed, so cycle.complete/pipeline.end
                        # name the real cause instead of "route_back".
                        if [[ -n "${_CYCLE_ROUTE_BACK_FALLBACK_REASON:-}" ]]; then
                            _CYCLE_LAST_TERMINATED_REASON="$_CYCLE_ROUTE_BACK_FALLBACK_REASON"
                        fi
                        warn "Cycle $_cyc_id route_back budget/cap exhausted (pass $_RUNNER_ROUTE_BACK_PASSES/$_RUNNER_ROUTE_BACK_BUDGET) → fallback rc=$_rc"
                    fi
                    _cycle_handle_terminal_rc "$_rc" "$_cyc_id" "$state_file" || true
                    # #1217 review fix (SHOULD-FIX): a previously-unconverged
                    # cycle that now converges (rc=0, e.g. on a route_back
                    # replay) clears the stale unconverged signal so the
                    # final-status aggregator doesn't report a false-fail after
                    # a successful correction. Scoped to the SAME cycle id so a
                    # different, still-unconverged cycle is never masked when an
                    # unrelated cycle converges.
                    if [[ $_rc -eq 0 && "${_RUNNER_CYCLE_UNCONVERGED_ID:-}" == "$_cyc_id" ]]; then
                        _RUNNER_CYCLE_UNCONVERGED=0
                        _RUNNER_CYCLE_UNCONVERGED_REASON=""
                        _RUNNER_CYCLE_UNCONVERGED_ID=""
                        _RUNNER_CYCLE_UNCONVERGED_ON_MAX=""
                    fi
                    # #511 Pin 7 / #527 / #528 — halt-vs-continue rc table:
                    # rc 0 (converged)         → CONTINUE; happy path.
                    # rc 1 (max_iter)          → CONTINUE; review gate runs;
                    #                            mark _RUNNER_CYCLE_UNCONVERGED=1.
                    # rc 2 (plateau)           → CONTINUE; review gate runs;
                    #                            mark _RUNNER_CYCLE_UNCONVERGED=1.
                    # rc 3 (divergence)        → CONTINUE; review gate runs;
                    #                            mark _RUNNER_CYCLE_UNCONVERGED=1.
                    # rc 4 (config_invalid)    → HALT; status=interrupted.
                    # rc 5 (blocked, #528)     → HALT; status=interrupted. Review
                    #                            does NOT run on blocked (upstream
                    #                            input structurally broken).
                    # rc 7 (blocked_on_scope,  → HALT; status=interrupted. #840:
                    #   ADR-030)                  build needs out-of-scope files
                    #                            the policy won't grant; review is
                    #                            pointless. Operator widens scope.
                    # rc 8 (blocking_member    → HALT; status=failed. ADR-013: a
                    #   _failure, ADR-013)        blocking CQ member (cq-preflight,
                    #                            cq-audit-plan, cq-cycle) failed.
                    # rc 130 (aborted=SIGINT)  → HALT; status=interrupted.
                    # rc 143 (aborted=SIGTERM) → HALT; status=interrupted (Wave 15-F).
                    if [[ $_rc -eq 4 || $_rc -eq 5 || $_rc -eq 6 || $_rc -eq 7 || $_rc -eq 8 || $_rc -eq 9 || $_rc -eq 10 || $_rc -eq 130 || $_rc -eq 143 ]]; then
                        # #1024: rc=9 = llm_unavailable; status=aborted (distinct from interrupted).
                        if [[ $_rc -eq 9 ]]; then
                            _set_pipeline_status "$state_file" "aborted"
                            _zbuild_runner_write_llm_abort "$state_file"
                            eb_emit_event "pipeline.aborted" "cycle=$_cyc_id" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                "reason=llm_unavailable" "status=aborted" 2>/dev/null || true
                            eb_emit_event "pipeline.end" "status=aborted" "cycle=$_cyc_id" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue"
                            _render_pipeline_end "aborted"
                            _runner_ended=true
                            error "Cycle $_cyc_id aborted rc=$_rc: LLM CLI unavailable"
                            return 9
                        fi
                        # #1052: rc=10 = scope_too_large; status=aborted (mirrors rc=9).
                        # The plan stage exhausted its turn budget without a complete
                        # plan — the issue is too large. Terminal, distinct from
                        # rc=8 blocking_member_failure and rc=9 llm_unavailable.
                        if [[ $_rc -eq 10 ]]; then
                            _set_pipeline_status "$state_file" "aborted"
                            eb_emit_event "pipeline.aborted" "cycle=$_cyc_id" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                "reason=scope_too_large" "status=aborted" 2>/dev/null || true
                            eb_emit_event "pipeline.end" "status=aborted" "cycle=$_cyc_id" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue"
                            _render_pipeline_end "aborted"
                            _runner_ended=true
                            error "Cycle $_cyc_id aborted rc=$_rc: scope_too_large — SPLIT THIS ISSUE"
                            return 10
                        fi
                        # ADR-027 (Wave 17-B #703): rc=6 cycle_abort halts
                        # the pipeline + propagates outward distinctly from
                        # signal-driven aborts (rc=130/143) and blocked
                        # (rc=5). The runner emits pipeline.aborted with
                        # reason=cycle_abort and returns rc=6 to its caller.
                        # ADR-013: rc=8 (blocking_member_failure) → status=failed.
                        if [[ $_rc -eq 8 ]]; then
                            _set_pipeline_status "$state_file" "failed"
                        else
                            _set_pipeline_status "$state_file" "interrupted"
                        fi
                        # #612 / Wave 15-F (#686): distinguish signal-driven cycle
                        # abort (SIGINT or SIGTERM) so the postmortem event stream
                        # can answer "was this Ctrl-C / kill?" without parsing
                        # per-cycle terminated_reason fields.
                        if [[ $_rc -eq 130 || $_rc -eq 143 || $_rc -eq 6 ]]; then
                            local _abort_reason="sigint"
                            [[ $_rc -eq 143 ]] && _abort_reason="sigterm"
                            [[ $_rc -eq 6 ]] && _abort_reason="cycle_abort"
                            _RUNNER_SIGINT_RECEIVED=1
                            _RUNNER_ABORT_REASON="$_abort_reason"
                            eb_emit_event "pipeline.aborted" "cycle=$_cyc_id" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                "reason=$_abort_reason" "status=interrupted" 2>/dev/null || true
                        fi
                        eb_emit_event "pipeline.end" "status=failed" "cycle=$_cyc_id" \
                            "reason=$_CYCLE_LAST_TERMINATED_REASON" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue"
                        _render_pipeline_end "failed"
                        _runner_ended=true
                        error "Cycle $_cyc_id terminated rc=$_rc reason=$_CYCLE_LAST_TERMINATED_REASON"
                        # Codex P2 on #616 / Wave 15-F: propagate rc=130 + rc=143
                        # distinctly so callers can distinguish Ctrl-C / kill from
                        # a generic cycle failure.
                        if [[ $_rc -eq 130 || $_rc -eq 143 || $_rc -eq 6 ]]; then
                            return $_rc
                        fi
                        return 1
                    fi
                    if [[ $_rc -eq 1 || $_rc -eq 2 || $_rc -eq 3 ]]; then
                        _RUNNER_CYCLE_UNCONVERGED=1
                        _RUNNER_CYCLE_UNCONVERGED_REASON="$_CYCLE_LAST_TERMINATED_REASON"
                        _RUNNER_CYCLE_UNCONVERGED_ID="$_cyc_id"
                        # #796 / ADR-021 v3 R1: capture on_max value for the
                        # final-status aggregator. _TPL_CYCLE_ON_MAX_<id> is
                        # populated by the template parser.
                        local _on_max_var="_TPL_CYCLE_ON_MAX_${_cyc_id//-/_}"
                        _RUNNER_CYCLE_UNCONVERGED_ON_MAX="${!_on_max_var:-abort}"
                        # Propagate the cycle's unconverged signal as the until-stage
                        # failure (typically `test`) so review's `_review_derive_test_status`
                        # sees an unambiguous failure. Without this, review's #485
                        # coercion may default to "unknown" depending on whether the
                        # test plugin wrote test-results.json before the cycle bailed.
                        # ADR-021 amendment (#527): runner sets stage_statuses[<until>]=failed
                        # so review's ADR-019 fail-closed gate has a clean signal.
                        local _until_stage_var="_TPL_CYCLE_UNTIL_STAGE_${_cyc_id//-/_}"
                        local _until_stage="${!_until_stage_var:-test}"
                        # #766: _update_stage_status may fail when the until-stage
                        # isn't yet in stage_statuses (e.g., it's a cycle member).
                        # Best-effort; the cycle.unconverged event below is the
                        # durable signal.
                        _update_stage_status "$state_file" "$_until_stage" "failed" || true
                        eb_emit_event "cycle.unconverged" \
                            "cycle_id=$_cyc_id" \
                            "iter=${_CYCLE_LAST_ITERATIONS:-0}" \
                            "reason=$_CYCLE_LAST_TERMINATED_REASON" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue" \
                            2>/dev/null || true
                        # #938: gate the message on on_max so it matches the
                        # status _runner_compute_final_status computes (continue
                        # + downstream approve → complete, not failed).
                        warn "$(_runner_unconverged_msg "$_cyc_id" "$_rc" "$_CYCLE_LAST_TERMINATED_REASON" "$_RUNNER_CYCLE_UNCONVERGED_ON_MAX")"
                    fi
                    ;;
                parallel:*)
                    # ADR-039 (#1131): a parallel stage group occupies ONE
                    # cardinal slot (like a cycle). Render the entry banner,
                    # publish the cardinal as ZBUILD_SEQ_PREFIX so members render
                    # `<cardinal>.<slot>` seq labels, then dispatch the group.
                    local _pg_id="${_unit#parallel:}"
                    local _pg_safe="${_pg_id//-/_}"
                    local _pg_flow_var="_TPL_PARALLEL_FLOW_${_pg_safe}"
                    local _pg_flow_csv="${!_pg_flow_var:-}"
                    local _pg_max_var="_TPL_PARALLEL_MAX_${_pg_safe}"
                    local _pg_max="${!_pg_max_var:-auto}"
                    _render_parallel_entry "$_pg_id" "$_pg_max" "$_pg_flow_csv"
                    export ZBUILD_SEQ_PREFIX="$_runner_cardinal"
                    # `&& _rc=0 || _rc=$?` captures the rc without tripping set -e.
                    parallel_group_run "$_pg_id" "$state_dir" "$state_file" && _rc=0 || _rc=$?
                    unset ZBUILD_SEQ_PREFIX
                    if [[ $_rc -eq 130 || $_rc -eq 143 ]]; then
                        local _pg_abort_reason="sigint"
                        [[ $_rc -eq 143 ]] && _pg_abort_reason="sigterm"
                        _RUNNER_SIGINT_RECEIVED=1
                        _RUNNER_ABORT_REASON="$_pg_abort_reason"
                        _set_pipeline_status "$state_file" "interrupted"
                        eb_emit_event "pipeline.aborted" "parallel=$_pg_id" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue" \
                            "reason=$_pg_abort_reason" "status=interrupted" 2>/dev/null || true
                        eb_emit_event "pipeline.end" "status=failed" "parallel=$_pg_id" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue"
                        _render_pipeline_end "failed"
                        _runner_ended=true
                        error "Parallel group $_pg_id aborted (rc=$_rc)"
                        return "$_rc"
                    fi
                    if [[ $_rc -ne 0 ]]; then
                        # rc=1 (on_member_error=collect, a member failed) or a
                        # config error → halt the pipeline as failed.
                        _set_pipeline_status "$state_file" "failed"
                        eb_emit_event "pipeline.end" "status=failed" "parallel=$_pg_id" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue"
                        _render_pipeline_end "failed"
                        _runner_ended=true
                        error "Parallel group $_pg_id failed (rc=$_rc)"
                        return 1
                    fi
                    ;;
                stage:*)
                    local _ust="${_unit#stage:}"
                    # Re-enter the legacy loop for a single stage by re-using
                    # active_stages — simplest correct path: run that stage's
                    # body inline via cycle_dispatch_stage (gives same plugin
                    # path); then mirror state writes the original loop does.
                    eb_emit_event "stage.start" "stage=$_ust" \
                        || { _r=$?; warn "eb_emit_event stage.start failed (rc=$_r, continuing — disk/perm/lock?)"; true; }
                    _RUNNER_STAGE_START_MS[$_ust]="$(_runner_now_ms)"
                    _render_stage_divider "$_ust"
                    local _sc; _sc="$(_stage_color "$_ust")"
                    local _ts; _ts="$(_runner_now_short)"
                    echo -e "${CYAN}${BOLD}▸${RESET} Running stage: ${_sc}${BOLD}${_ust}${RESET}  ${DIM}(started ${_ts})${RESET}" >&2
                    export ZBUILD_CURRENT_STAGE="$_ust"
                    # #682: linear stage in cycle-aware dispatch — cardinal label.
                    export ZBUILD_STAGE_IO_SEQ_LABEL="$_runner_cardinal"
                    # ADR-043: refresh the per-run scope allowlist for this stage.
                    _runner_export_scope_allowlist "$state_dir"
                    set +e; cycle_dispatch_stage "$_ust" 0 "$state_file"; _rc=$?; set -e
                    unset ZBUILD_CURRENT_STAGE ZBUILD_STAGE_IO_SEQ_LABEL
                    if [[ $_rc -ne 0 ]]; then
                        _update_stage_status "$state_file" "$_ust" "failed"
                        if [[ $_rc -eq 9 ]]; then
                            # #1024: llm_unavailable abort — status=aborted.
                            _set_pipeline_status "$state_file" "aborted"
                            _zbuild_runner_write_llm_abort "$state_file"
                            eb_emit_event "stage.fail" "stage=$_ust" "rc=$_rc" \
                                || { _r=$?; warn "eb_emit_event stage.fail failed (rc=$_r)"; true; }
                            eb_emit_event "pipeline.aborted" "stage=$_ust" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                "reason=llm_unavailable" "status=aborted" 2>/dev/null || true
                            eb_emit_event "pipeline.end" "status=aborted" "stage=$_ust" "rc=$_rc" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                || { _r=$?; warn "eb_emit_event pipeline.end status=aborted failed (rc=$_r)"; true; }
                            _render_pipeline_end "aborted" "$_ust" "$_rc"
                            _runner_ended=true
                            error "Stage $_ust aborted (rc=$_rc): LLM CLI unavailable"
                            return 9
                        fi
                        # #1052: rc=10 = scope_too_large — plan turn budget exhausted;
                        # status=aborted (mirrors rc=9). Distinct from rc=8/rc=9.
                        if [[ $_rc -eq 10 ]]; then
                            _set_pipeline_status "$state_file" "aborted"
                            eb_emit_event "stage.fail" "stage=$_ust" "rc=$_rc" \
                                || { _r=$?; warn "eb_emit_event stage.fail failed (rc=$_r)"; true; }
                            eb_emit_event "pipeline.aborted" "stage=$_ust" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                "reason=scope_too_large" "status=aborted" 2>/dev/null || true
                            eb_emit_event "pipeline.end" "status=aborted" "stage=$_ust" "rc=$_rc" \
                                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                                || { _r=$?; warn "eb_emit_event pipeline.end status=aborted failed (rc=$_r)"; true; }
                            _render_pipeline_end "aborted" "$_ust" "$_rc"
                            _runner_ended=true
                            error "Stage $_ust aborted (rc=$_rc): scope_too_large — SPLIT THIS ISSUE"
                            return 10
                        fi
                        _set_pipeline_status "$state_file" "interrupted"
                        eb_emit_event "stage.fail" "stage=$_ust" "rc=$_rc" \
                            || { _r=$?; warn "eb_emit_event stage.fail failed (rc=$_r, continuing — disk/perm/lock?)"; true; }
                        eb_emit_event "pipeline.end" "status=failed" "stage=$_ust" "rc=$_rc" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue" \
                            || { _r=$?; warn "eb_emit_event pipeline.end status=failed failed (rc=$_r, continuing — disk/perm/lock?)"; true; }
                        _render_pipeline_end "failed" "$_ust" "$_rc"
                        _runner_ended=true
                        error "Stage $_ust failed (rc=$_rc)"
                        return 1
                    fi
                    _update_stage_status "$state_file" "$_ust" "complete"
                    _zbuild_state_set_stage_verdict "$state_file" "$_ust" "${_CYCLE_DISPATCH_VERDICT:-pass}"
                    eb_emit_event "stage.complete" "stage=$_ust" "verdict=${_CYCLE_DISPATCH_VERDICT:-pass}" \
                        || { _r=$?; warn "eb_emit_event stage.complete failed (rc=$_r, continuing — disk/perm/lock?)"; true; }
                    ;;
            esac
        done
        # #527: when any cycle terminated unconverged (rc∈{1,2,3}), the pipeline
        # outcome USED TO BE always `failed`. #796 / ADR-021 v3 R1 amends this:
        # on_max=continue MUST NOT propagate to terminal failure. The
        # aggregator now honors per-cycle on_max semantics + downstream
        # success. The cycle.unconverged event still fires for forensics.
        #
        # Determine downstream success. Two paths:
        #  - No unconverged: treat as success (preserves pre-#796 behavior
        #    where a converged pipeline is always pipeline=complete).
        #  - Unconverged with on_max=continue: check review.json verdict.
        #    If review approved/passed, downstream rescued; else not.
        local _downstream_success=1
        if [[ "${_RUNNER_CYCLE_UNCONVERGED:-0}" -eq 1 ]]; then
            local _review_json
            _review_json="$(dirname "$state_file")/artifacts/review.json"
            if [[ -f "$_review_json" ]]; then
                local _review_verdict
                _review_verdict="$(jq -r '.verdict // empty' "$_review_json" 2>/dev/null || echo)"
                case "$_review_verdict" in
                    approve|pass) _downstream_success=1 ;;
                    *) _downstream_success=0 ;;
                esac
            else
                # No review.json on an unconverged run → nothing rescued; failed.
                _downstream_success=0
            fi
        fi

        local _final_status=""
        _runner_compute_final_status \
            "${_RUNNER_CYCLE_UNCONVERGED:-0}" \
            "$_RUNNER_CYCLE_UNCONVERGED_ON_MAX" \
            "$_downstream_success" \
            _final_status

        if [[ "$_final_status" == "failed" ]]; then
            _set_pipeline_status "$state_file" "failed"
            eb_emit_event "pipeline.end" "status=failed" \
                "cycle=$_RUNNER_CYCLE_UNCONVERGED_ID" \
                "reason=$_RUNNER_CYCLE_UNCONVERGED_REASON" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _runner_ended=true
            error "Pipeline failed — cycle '$_RUNNER_CYCLE_UNCONVERGED_ID' did not converge (reason=$_RUNNER_CYCLE_UNCONVERGED_REASON); run_id=$_runner_run_id"
            return 1
        fi

        _set_pipeline_status "$state_file" "complete"
        eb_emit_event "pipeline.end" "status=success" "run_id=$_runner_run_id" "issue=$_runner_issue"
        _render_pipeline_end "complete"
        _runner_ended=true
        if [[ "${_RUNNER_CYCLE_UNCONVERGED:-0}" -eq 1 ]]; then
            # #796: succeeded with warning — cycle didn't converge but on_max=continue
            warn "Pipeline complete with warning — cycle '$_RUNNER_CYCLE_UNCONVERGED_ID' did not converge (reason=$_RUNNER_CYCLE_UNCONVERGED_REASON), on_max=continue allowed fall-through"
        fi
        success "Pipeline complete — run_id=$_runner_run_id"
        return 0
    fi

    local stage
    # #682 (Wave 15-D): cardinal counter for the legacy linear stage loop.
    # Increments per active stage; exported as ZBUILD_STAGE_IO_SEQ_LABEL so the
    # stage-io banner renders `seq=N` reflecting position in the pipeline rather
    # than the per-stage cardinal (which collides across stages on retries).
    local _runner_linear_cardinal=0
    for stage in "${active_stages[@]}"; do
        # ADR-025 (Wave 15-B #684) pre-flight: the sentinel may have been
        # armed by SIGINT or SIGTERM between iterations. Bail BEFORE spawning
        # the next stage so the abort observes within one stage boundary.
        # Existing post-flight rc=130/143 check at the end of this loop body
        # stays. Wave 15-F (#686): if the signal trap recorded reason=sigterm,
        # propagate 143 rather than 130 so callers see the distinct rc.
        if ! _zbuild_check_abort; then
            _RUNNER_SIGINT_RECEIVED=1
            if [[ "${_RUNNER_ABORT_REASON:-sigint}" == "sigterm" ]]; then
                return 143
            fi
            return 130
        fi
        _runner_linear_cardinal=$(( _runner_linear_cardinal + 1 ))
        # When resuming, skip stages already marked complete unless --from-stage overrides
        if $resume_mode && [[ -z "$skip_until_stage" ]]; then
            local stage_status
            stage_status="$(get_state_field "$state_file" ".stage_statuses[\"$stage\"]" '')"
            if [[ "$stage_status" == "complete" ]]; then
                # #507: if the primary artifact has gone missing between runs
                # (operator deleted state/artifacts/, partial restore, etc.)
                # emit a stale-artifact warning so the operator sees a ⚠
                # instead of silently trusting the persisted status.
                local _sk_plugin_dir _sk_manifest="" _sk_prim_path="" _sk_resolved=""
                _sk_plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" 2>/dev/null || true)"
                if [[ -n "$_sk_plugin_dir" ]]; then
                    _sk_manifest="$_sk_plugin_dir/manifest.yaml"
                    _sk_prim_path="$(_verdict_primary_output_path "$_sk_manifest" 2>/dev/null || true)"
                    if [[ -n "$_sk_prim_path" ]]; then
                        _sk_resolved="$(_verdict_resolve_path "$_sk_prim_path" "$state_dir")"
                        if [[ ! -s "$_sk_resolved" ]]; then
                            eb_emit_event "stage.verdict.stale_artifact" \
                                "stage=$stage" "path=$_sk_resolved" \
                                "run_id=$_runner_run_id"
                            local _sk_sc; _sk_sc="$(_stage_color "$stage")"
                            echo -e "${YELLOW}${BOLD}⚠${RESET} Stage ${_sk_sc}${BOLD}${stage}${RESET} complete (stale: primary artifact missing)" >&2
                            continue
                        fi
                    fi
                fi
                info "Skipping already-complete stage: $stage"
                continue
            fi
        fi

        # --from-stage: skip until we reach the named stage
        if [[ -n "$skip_until_stage" && "$stage" != "$skip_until_stage" ]]; then
            info "Skipping stage: $stage (awaiting $skip_until_stage)"
            continue
        fi
        # Once we reach the target stage, clear the skip gate
        skip_until_stage=""

        eb_emit_event "stage.start" "stage=$stage"
        # #508: cache stage start (ms) BEFORE the divider call so the divider
        # and Running line share a consistent start-time wall clock under the
        # ZBUILD_STAGE_IO_NOW_MS_OVERRIDE pin used by goldens.
        _RUNNER_STAGE_START_MS[$stage]="$(_runner_now_ms)"
        # #646: emit a single blank line BEFORE the stage divider so
        # consecutive stages don't render flush against each other. The
        # divider itself already prints a leading \n; this additional blank
        # gives the operator a clear vertical break between the previous
        # stage's `── end stage-io: <prev> ──` line (or any post-loop warns)
        # and the next stage's `━━━ <stage> ━━━` boundary. Wave 11B.
        printf '\n' >&2
        # #492 v5: heavy divider + stage-color stage name on the "Running" line.
        _render_stage_divider "$stage"
        local _sc_color; _sc_color="$(_stage_color "$stage")"
        # #508: append "  (started HH:MM:SS UTC)" in DIM. Two-space separator
        # before the paren matches the metadata-trailer convention used by
        # stage-io banner footers. Timestamp text stays outside the color
        # escape so NO_COLOR strips ANSI but preserves the timestamp.
        local _sc_ts; _sc_ts="$(_runner_now_short)"
        echo -e "${CYAN}${BOLD}▸${RESET} Running stage: ${_sc_color}${BOLD}${stage}${RESET}  ${DIM}(started ${_sc_ts})${RESET}" >&2

        # ADR-015 v1 (#438): expose current stage to the LLM router so
        # capture_stage_io can attribute artifacts to the right stage.
        # Unset after plugin invocation to avoid leaking across stage boundaries.
        export ZBUILD_CURRENT_STAGE="$stage"
        # #682 (Wave 15-D): expose cardinal seq label so stage-io banner shows
        # the linear pipeline position (e.g. intake=1, plan=2, build=3, review=4)
        # instead of the per-stage retry counter. Banner reads this via
        # ZBUILD_STAGE_IO_SEQ_LABEL fallback inside stage_io_begin.
        export ZBUILD_STAGE_IO_SEQ_LABEL="$_runner_linear_cardinal"
        # ADR-043: refresh the per-run scope allowlist for this stage so the
        # router can self-redact (empty until plan.json exists — additive only).
        _runner_export_scope_allowlist "$state_dir"

        # Intentional fail-open: missing/empty template roles = no-template path (handled below)
        local roles_out; roles_out="$(template_stage_roles "$stage" 2>/dev/null || true)"
        local strategy; strategy="$(template_stage_strategy "$stage" 2>/dev/null || echo "fanout")"
        local plugin_dir="" rc=0

        if [[ -z "$roles_out" ]]; then
            # No roles in template — resolve by stage ID (backward-compat).
            # Intentional fail-open: _find_plugin_for_stage returns non-zero when not found;
            # the empty-result branch below emits stage.fail and halts the pipeline (fail-closed).
            plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
            if [[ -z "$plugin_dir" ]]; then
                _update_stage_status "$state_file" "$stage" "failed"
                _set_pipeline_status "$state_file" "interrupted"
                eb_emit_event "stage.fail" "stage=$stage" "reason=no_plugin"
                eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _render_pipeline_end "failed" "$stage"
                _runner_ended=true
                error "No plugin registered for required stage '$stage'"
                return 1
            fi
            set +e; plugin_hook_call "$plugin_dir" run "$stage" "$state_file"; rc=$?; set -e
            # ARCHITECTURE.md §2: enforce artifact contract after plugin run (fail-closed)
            if [[ $rc -eq 0 ]]; then
                _check_artifact_contract "$plugin_dir" "$state_dir" "$stage"
            fi
        else
            # Strategy dispatch via orch contract (ADR-011, issue #222).
            # Pool ID: stage-scoped, unique per run to prevent pool collision across stages.
            local pool_id
            pool_id="zbuild-${stage:0:20}-$$-$(date +%s%N 2>/dev/null || date +%s)"
            orch_spawn "$pool_id" || {
                _update_stage_status "$state_file" "$stage" "failed"
                _set_pipeline_status "$state_file" "interrupted"
                eb_emit_event "stage.fail" "stage=$stage" "reason=orch_spawn_failed"
                eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _render_pipeline_end "failed" "$stage"
                _runner_ended=true
                error "Stage $stage: orch_spawn failed for pool $pool_id"
                return 1
            }

            # Allow _ZBUILD_STRATEGY_OVERRIDE for testing; normal path reads $strategy.
            local _effective_strategy="${_ZBUILD_STRATEGY_OVERRIDE:-$strategy}"

            rc=0
            case "$_effective_strategy" in
                composite)
                    set +e; _strategy_run_composite "$pool_id" "$stage" "$roles_out" "$state_file" "$plugins_root"; rc=$?; set -e
                    ;;
                sequential)
                    set +e; _strategy_run_sequential "$pool_id" "$stage" "$roles_out" "$state_file" "$plugins_root"; rc=$?; set -e
                    ;;
                *)
                    # fanout (default) — parallel dispatch
                    set +e; _strategy_run_fanout "$pool_id" "$stage" "$roles_out" "$state_file" "$plugins_root"; rc=$?; set -e
                    ;;
            esac

            # rc=4 from strategy means "no plugin found for any role" — fall back to direct ID
            # match (backward-compat for plugins named by stage ID rather than role).
            # rc=1/2 are execution failures; the fallback must NOT fire for those, or a failed
            # role-based stage could be silently masked by a passing stage-id plugin.
            if [[ $rc -eq 4 ]]; then
                plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
                if [[ -z "$plugin_dir" ]]; then
                    _update_stage_status "$state_file" "$stage" "failed"
                    _set_pipeline_status "$state_file" "interrupted"
                    eb_emit_event "stage.fail" "stage=$stage" "reason=no_plugin"
                    eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                        "run_id=$_runner_run_id" "issue=$_runner_issue"
                    _render_pipeline_end "failed" "$stage"
                    _runner_ended=true
                    error "No plugin registered for required stage '$stage' (roles: $roles_out)"
                    return 1
                fi
                set +e; plugin_hook_call "$plugin_dir" run "$stage" "$state_file"; rc=$?; set -e
                # ARCHITECTURE.md §2: enforce artifact contract after plugin run (fail-closed)
                if [[ $rc -eq 0 ]]; then
                    _check_artifact_contract "$plugin_dir" "$state_dir" "$stage"
                fi
            fi
            # rc=0: artifact contracts already checked inside fanout/sequential strategies.
        fi

        if [[ $rc -eq 0 ]]; then
            _update_stage_status "$state_file" "$stage" "complete"
            # #507: resolve verdict from the plugin's manifest-declared primary
            # output. Glyph + color reflect the actual verdict, not just rc=0.
            local _verdict_manifest="" _verdict_class="pass"
            local _verdict_plugin_dir=""
            _verdict_plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" 2>/dev/null || true)"
            if [[ -n "$_verdict_plugin_dir" ]]; then
                _verdict_manifest="$_verdict_plugin_dir/manifest.yaml"
            fi
            _verdict_class="$(runner_read_stage_verdict "$state_dir" "$_verdict_manifest" "$stage" 0)"
            # Persist verdict for observability/resume (schema-additive).
            _zbuild_state_set_stage_verdict "$state_file" "$stage" "$_verdict_class"
            eb_emit_event "stage.complete" "stage=$stage" "verdict=$_verdict_class"
            local _vg _vc _sc2 _cc_ts _cc_dur
            _vg="$(verdict_glyph "$_verdict_class")"
            _vc="$(verdict_color "$_verdict_class")"
            _sc2="$(_stage_color "$stage")"
            # #508: append "  (finished HH:MM:SS UTC · <dur>)" in DIM.
            _cc_ts="$(_runner_now_short)"
            _cc_dur="$(_runner_duration_token "$stage")"
            echo -e "${_vc}${BOLD}${_vg}${RESET} Stage ${_sc2}${BOLD}${stage}${RESET} complete  ${DIM}(finished ${_cc_ts} · ${_cc_dur})${RESET}" >&2
            # After intake completes, append user-provided scope overrides to
            # scope-manifest.md so intake's detection output is preserved alongside
            # the operator's --scope paths.
            if [[ "$stage" == "intake" && -f "$state_dir/scope-override.md" ]]; then
                local scope_manifest="$state_dir/scope-manifest.md"
                # Extract only '+ <path>' lines from the override file and append.
                # Intentional fail-open: scope-override.md may not exist (no --scope flag used)
                grep '^+ ' "$state_dir/scope-override.md" >> "$scope_manifest" 2>/dev/null || true
                info "Appended scope override entries to $scope_manifest"
            fi
        elif [[ $rc -eq 2 ]]; then
            # Partial fanout: at least one platform succeeded and at least one failed.
            # State uses "failed" (ADR-006 enum); partial detail is in the event payload.
            _update_stage_status "$state_file" "$stage" "failed"
            _set_pipeline_status "$state_file" "interrupted"
            eb_emit_event "stage.fail" "stage=$stage" "reason=partial"
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _render_pipeline_end "failed" "$stage"
            _runner_ended=true
            # #508: failure-line timestamp stays DIM (not red) — the clock
            # isn't the failure. error() handles the ✗/red on the prefix.
            local _f1_ts _f1_dur
            _f1_ts="$(_runner_now_short)"
            _f1_dur="$(_runner_duration_token "$stage")"
            error "Stage $stage partially failed  ${DIM}(finished ${_f1_ts} · ${_f1_dur})${RESET}"
            return 1
        else
            # ADR-001: exit 1 (recoverable) and 2 (fatal) both halt v1.
            _update_stage_status "$state_file" "$stage" "failed"
            # #1024: rc=9 = llm_unavailable abort — pipeline status is "aborted",
            # not "interrupted". Handle before the general failure path.
            if [[ $rc -eq 9 ]]; then
                _set_pipeline_status "$state_file" "aborted"
                _zbuild_runner_write_llm_abort "$state_file"
                eb_emit_event "stage.fail" "stage=$stage" "rc=$rc"
                eb_emit_event "pipeline.aborted" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue" \
                    "reason=llm_unavailable" "status=aborted" 2>/dev/null || true
                eb_emit_event "pipeline.end" "status=aborted" "stage=$stage" "rc=$rc" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _render_pipeline_end "aborted" "$stage" "$rc"
                _runner_ended=true
                local _fa_ts _fa_dur
                _fa_ts="$(_runner_now_short)"
                _fa_dur="$(_runner_duration_token "$stage")"
                error "Stage $stage aborted (rc=$rc, finished ${_fa_ts} · ${_fa_dur}): LLM CLI unavailable"
                return 9
            fi
            # #1052: rc=10 = scope_too_large abort — pipeline status is "aborted"
            # (mirrors the rc=9 llm_unavailable path). Plan exhausted its turn
            # budget without a complete plan — the issue is too large. Distinct
            # from rc=8 (blocking_member_failure) and rc=9 (llm_unavailable).
            if [[ $rc -eq 10 ]]; then
                _set_pipeline_status "$state_file" "aborted"
                eb_emit_event "stage.fail" "stage=$stage" "rc=$rc"
                eb_emit_event "pipeline.aborted" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue" \
                    "reason=scope_too_large" "status=aborted" 2>/dev/null || true
                eb_emit_event "pipeline.end" "status=aborted" "stage=$stage" "rc=$rc" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _render_pipeline_end "aborted" "$stage" "$rc"
                _runner_ended=true
                local _sa_ts _sa_dur
                _sa_ts="$(_runner_now_short)"
                _sa_dur="$(_runner_duration_token "$stage")"
                error "Stage $stage aborted (rc=$rc, finished ${_sa_ts} · ${_sa_dur}): scope_too_large — SPLIT THIS ISSUE"
                return 10
            fi
            _set_pipeline_status "$state_file" "interrupted"
            eb_emit_event "stage.fail" "stage=$stage" "rc=$rc"
            # #612 / Wave 15-F (#686): rc=130 (SIGINT) or rc=143 (SIGTERM)
            # from a stage means the signal-propagation chain reached us
            # (route_to_model_loop saw child rc=130/143 → build plugin
            # propagated → here). Emit `pipeline.aborted reason=<sigint|sigterm>`
            # so postmortems can distinguish Ctrl-C / kill from OOM/fatal errors.
            if [[ $rc -eq 130 || $rc -eq 143 ]]; then
                local _abort_reason="sigint"
                [[ $rc -eq 143 ]] && _abort_reason="sigterm"
                _RUNNER_SIGINT_RECEIVED=1
                _RUNNER_ABORT_REASON="$_abort_reason"
                eb_emit_event "pipeline.aborted" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue" \
                    "reason=$_abort_reason" "status=interrupted" 2>/dev/null || true
            fi
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" "rc=$rc" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _render_pipeline_end "failed" "$stage" "$rc"
            _runner_ended=true
            # #508: append timestamp + duration; rc stays in front of the
            # paren so the metadata reads "(rc=N, finished ... · ...s)".
            local _f2_ts _f2_dur
            _f2_ts="$(_runner_now_short)"
            _f2_dur="$(_runner_duration_token "$stage")"
            error "Stage $stage failed (rc=$rc, finished ${_f2_ts} · ${_f2_dur})"
            # Codex P2 on #616 / Wave 15-F: propagate rc=130 + rc=143
            # distinctly so callers can distinguish operator Ctrl-C / kill
            # from a generic stage failure.
            if [[ $rc -eq 130 || $rc -eq 143 ]]; then
                return $rc
            fi
            return 1
        fi

        # ADR-015 v1 (#438): clear the current-stage env so subsequent code
        # running between stages doesn't accidentally tag artifacts.
        # #682: also unset the seq label so it doesn't leak across stages.
        unset ZBUILD_CURRENT_STAGE ZBUILD_STAGE_IO_SEQ_LABEL
    done

    _set_pipeline_status "$state_file" "complete"
    eb_emit_event "pipeline.end" "status=success" "run_id=$_runner_run_id" "issue=$_runner_issue"
    # #525: banner uses ADR-006 state enum "complete" while persisted event
    # payload remains "status=success" (existing consumer contract).
    _render_pipeline_end "complete"
    _runner_ended=true
    success "Pipeline complete — run_id=$_runner_run_id"
    return 0
}

# Only run main when executed directly, not when sourced for function access.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
