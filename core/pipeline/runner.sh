#!/usr/bin/env bash
# core/pipeline/runner.sh — Pipeline orchestrator (issue #83, #208, #222, #225)
# ADR-001 (plugin contract), ADR-006 (resume contract), ADR-009 (platform-aware modularity),
# ADR-011 (pluggable orch backend)
set -euo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/core/output/stage-colors.sh"
source "$_ZBUILD_ROOT/core/state/atomic.sh"
source "$_ZBUILD_ROOT/core/state/resume.sh"
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

_usage() {
    cat <<EOF
Usage: runner.sh --issue <N>|--goal "<text>" [--dry-run] [--template <id>]
                 [--resume] [--from-stage <stage>] [--no-resume] [--force]
  --issue <N>       GitHub issue number to work
  --goal "<text>"   Pipeline goal description (alternative to --issue)
  --dry-run         Print the stage plan without executing anything
  --template <id>   Pipeline template to use (default: standard)
  --resume          Resume an existing run (skip completed stages)
  --from-stage <s>  Skip ahead to stage <s> when resuming (emits warning)
  --no-resume       Force fresh start even if an in_progress state exists
  --force           Resume even if status=aborted

Environment:
  ZBUILD_PLATFORM_OVERRIDE  Force a single platform; detection short-circuits.
  ZBUILD_SCOPE_PATHS        Newline-delimited scope paths; written as '+ <path>' entries.
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
    } >&2
}

main() {
    local issue="" goal="" dry_run=false template="standard"
    local resume_mode=false from_stage="" no_resume=false force=false

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
            --from-stage)
                [[ -z "${2:-}" ]] && { error "--from-stage requires a value"; _usage; return 2; }
                from_stage="$2"; shift 2 ;;
            --help|-h)  _usage; return 0 ;;
            *) error "Unknown argument: $1"; _usage; return 2 ;;
        esac
    done

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
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local template_file="$_ZBUILD_ROOT/config/templates/${template}.yaml"

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

    # Load template; fall back to built-in stage list if template missing or empty
    local active_stages=()
    if load_template "$template_file" 2>/dev/null && [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then
        active_stages=("${_TPL_STAGES[@]}")
    else
        warn "Template '$template' not found; using built-in stage list"
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
        local _cv_state_file_pf="${ZBUILD_STATE_FILE:-${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}/pipeline-state.json}"
        local _cv_stages_nl=""
        printf -v _cv_stages_nl '%s\n' "${active_stages[@]}"
        if ! _contract_validate_pipeline "$_cv_stages_nl" "$plugins_root" "$_cv_state_file_pf"; then
            error "Pre-flight contract validation failed (ZBUILD_CONTRACT_VALIDATOR=${ZBUILD_CONTRACT_VALIDATOR:-warn}). See above."
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
        # Fresh start: clear any existing state
        if [[ -f "$state_file" ]]; then
            rm -f "$state_file" "${state_file}.bak" "${state_file}.lock"
        fi
        # Sanitize ZBUILD_RUN_ID: strip characters unsafe in filenames (/, .., spaces, etc.)
        # to prevent path traversal when run_id is used in report-${run_id}.md filenames.
        local _raw_run_id="${ZBUILD_RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"
        _runner_run_id="${_raw_run_id//[^a-zA-Z0-9_.-]/}"
        # Fall back to generated ID if sanitization emptied the value
        [[ -z "$_runner_run_id" ]] && _runner_run_id="$(date +%Y%m%d%H%M%S)-$$"
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
    export ZBUILD_RUN_ID="$_runner_run_id"
    export ZBUILD_ISSUE="$_runner_issue"
    export ZBUILD_GOAL="${goal:-}"

    # Mark pipeline as in_progress
    _set_pipeline_status "$state_file" "in_progress"

    # Write user-provided scope paths to scope-override.md in '+ <path>' format.
    # After the intake stage completes, these entries are appended to scope-manifest.md
    # so intake's platform detection is preserved alongside the operator override.
    if [[ -n "${ZBUILD_SCOPE_PATHS:-}" ]]; then
        write_scope_override "$state_dir" "$_runner_run_id"
        info "Scope override paths written to $state_dir/scope-override.md"
    fi

    _runner_abort_trap() {
        [[ "$_runner_ended" == "true" ]] && return 0
        # Clean teardown (signal/OOM) → interrupted; operator cancel → aborted handled elsewhere.
        # Fail-closed: if we cannot mark the pipeline interrupted, emit an error event so the
        # operator can detect the unrecorded abort (was: || true, which silently dropped failures).
        if ! _set_pipeline_status "$_runner_state_file" "interrupted" 2>/dev/null; then
            eb_emit_event "pipeline.state.error" \
                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                "reason=abort_trap_set_status_failed" 2>/dev/null || true
        fi
        # Fail-closed: if abort event cannot be emitted, that is still non-fatal for the trap
        # itself (the process is exiting), but we do not silently swallow the failure.
        if ! eb_emit_event "pipeline.abort" \
            "run_id=$_runner_run_id" "issue=$_runner_issue" 2>/dev/null; then
            : # trap is exiting anyway; best-effort only
        fi
    }
    trap '_runner_abort_trap' EXIT

    # Detect platforms (writes state/platforms.json; returns "generic" if none found)
    local _DETECTED_PLATFORMS=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && _DETECTED_PLATFORMS+=("$p")
    done < <(detect_platforms "$PWD" "$state_dir" 2>/dev/null)
    [[ ${#_DETECTED_PLATFORMS[@]} -eq 0 ]] && _DETECTED_PLATFORMS=("generic")

    if $resume_mode; then
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

    local stage
    for stage in "${active_stages[@]}"; do
        # When resuming, skip stages already marked complete unless --from-stage overrides
        if $resume_mode && [[ -z "$skip_until_stage" ]]; then
            local stage_status
            stage_status="$(get_state_field "$state_file" ".stage_statuses[\"$stage\"]" '')"
            if [[ "$stage_status" == "complete" ]]; then
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
            eb_emit_event "stage.complete" "stage=$stage"
            # #492 v5: stage name carries its registry color; ✓ stays green.
            # #508: append "  (finished HH:MM:SS UTC · <dur>)" in DIM.
            local _cc; _cc="$(_stage_color "$stage")"
            local _cc_ts _cc_dur
            _cc_ts="$(_runner_now_short)"
            _cc_dur="$(_runner_duration_token "$stage")"
            echo -e "${GREEN}${BOLD}✓${RESET} Stage ${_cc}${BOLD}${stage}${RESET} complete  ${DIM}(finished ${_cc_ts} · ${_cc_dur})${RESET}" >&2
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
            _set_pipeline_status "$state_file" "interrupted"
            eb_emit_event "stage.fail" "stage=$stage" "rc=$rc"
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" "rc=$rc" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _runner_ended=true
            # #508: append timestamp + duration; rc stays in front of the
            # paren so the metadata reads "(rc=N, finished ... · ...s)".
            local _f2_ts _f2_dur
            _f2_ts="$(_runner_now_short)"
            _f2_dur="$(_runner_duration_token "$stage")"
            error "Stage $stage failed (rc=$rc, finished ${_f2_ts} · ${_f2_dur})"
            return 1
        fi

        # ADR-015 v1 (#438): clear the current-stage env so subsequent code
        # running between stages doesn't accidentally tag artifacts.
        unset ZBUILD_CURRENT_STAGE
    done

    _set_pipeline_status "$state_file" "complete"
    eb_emit_event "pipeline.end" "status=success" "run_id=$_runner_run_id" "issue=$_runner_issue"
    _runner_ended=true
    success "Pipeline complete — run_id=$_runner_run_id"
    return 0
}

# Only run main when executed directly, not when sourced for function access.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
