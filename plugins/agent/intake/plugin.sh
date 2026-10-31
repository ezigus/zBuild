#!/usr/bin/env bash
# plugins/agent/intake — Phase 0.5 stub (issue #85)
# Captures goal, sanitizes sentinels, reads platforms.json, writes
# state/scope-manifest.md + state/intake.md. No LLM call this phase.

[[ -n "${_ZBUILD_INTAKE_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
_INTAKE_DIR="$_ZBUILD_PLUGIN_DIR"
_INTAKE_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_INTAKE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/output/stage-io.sh
source "$_INTAKE_ROOT/core/output/stage-io.sh"

# shellcheck source=lib/sanitize.sh
source "$_INTAKE_DIR/lib/sanitize.sh"
# shellcheck source=lib/issue-state.sh
source "$_INTAKE_DIR/lib/issue-state.sh"
# shellcheck source=lib/requirements.sh
source "$_INTAKE_DIR/lib/requirements.sh"
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_INTAKE_ROOT/scripts/lib/stage-result.sh"

# ─── result writer (contract 3, #2366) ───────────────────────────────────────
# _intake_write_result <art_dir> <outcome> <reason> [data-json]
# One outcome from the engine's list (stage_result_write). There is no fallback
# directory: the engine names the artifact dir, and a result that cannot be
# written is reported, never skipped — a stage with no result reads as a
# pass-less run.
_intake_write_result() {
    local art_dir="$1" outcome="$2" reason="$3" data_json="${4:-}"
    if [[ -z "$art_dir" ]]; then
        error "intake: ZBUILD_ARTIFACT_DIR is not set — the engine gave intake nowhere to write intake-result.json"
        return 1
    fi
    stage_result_write "$art_dir/intake-result.json" "$outcome" "$reason" "$data_json" \
        && _INTAKE_RESULT_VERDICT="$outcome" && return 0
    error "intake: could not write $art_dir/intake-result.json"
    return 1
}

# A signal ends the stage: record it with the one word for it, then leave. A
# stage that already wrote its result has finished — a late signal (a graceful
# drain) leaves that result, and the exit status it implies, alone.
_intake_on_signal() {
    case "${_INTAKE_RESULT_VERDICT:-}" in
        pass) exit 0 ;;
        "")   _intake_write_result "${ZBUILD_ARTIFACT_DIR:-}" \
                  "${1:-$STAGE_SIGNAL_DISPOSITION}" "${2:-$STAGE_SIGNAL_REASON}" || true ;;
    esac
    exit 1
}

# _intake_compose_goal <issue_json> <comment_max_bytes>
# title + body, then qualifying comments under a labelled heading. Keeps
# OWNER/MEMBER/COLLABORATOR; drops github-actions, any [bot] login, and
# minimized comments. The cap is STATED in the text rather than applied
# silently: a shortened goal that still reads as complete is worse than an
# obviously truncated one (#1729).
_intake_compose_goal() {
    local json="${1-}" cap="${2:-4000}"
    [[ -n "$json" ]] || return 1
    local head cmts
    head="$(jq -r '
        (.title // "") as $t | (.body // "") as $b
        | if ($t | length) == 0 then ""
          elif ($b | length) == 0 then $t
          else $t + "\n\n" + $b end' <<< "$json" 2>/dev/null)" || return 1
    [[ -n "$head" ]] || return 1
    cmts="$(jq -r '
        [ (.comments // [])[]
          | select((.isMinimized // false) | not)
          # Bind first: after the pipe `.` is the ARRAY, so referencing
          # .authorAssociation on the right-hand side reads a field of the array
          # (null) and silently drops every comment.
          | select((.authorAssociation // "") as $a
                   | ["OWNER","MEMBER","COLLABORATOR"] | index($a))
          | select((.author.login // "") | endswith("[bot]") | not)
          | select((.author.login // "") != "github-actions")
          | (.body // "") | select(length > 0) ]
        | join("\n\n---\n\n")' <<< "$json" 2>/dev/null)" || cmts=""
    if [[ -n "$cmts" ]]; then
        if [[ "${#cmts}" -gt "$cap" ]]; then
            cmts="${cmts:0:$cap}"
            cmts="${cmts}"$'\n\n'"[… issue comments truncated at ${cap}B — read the issue for the full thread]"
        fi
        printf '%s\n\n## Additional context from issue comments\n\n%s' "$head" "$cmts"
    else
        printf '%s' "$head"
    fi
}

# ─── run ─────────────────────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
# Reads: ZBUILD_GOAL (env), ZBUILD_ISSUE (env, optional)
# Writes: $(dirname $state_file)/scope-manifest.md
#         $(dirname $state_file)/intake.md
#         $ZBUILD_ARTIFACT_DIR/intake-result.json (every exit path)
intake_run() {
    # The signal guard spans the whole stage and is ended on every return, so
    # the caller's own TERM/INT handlers come back (#2225 stage-signal).
    stage_signal_begin _intake_on_signal || return 1
    local rc=0
    _intake_run_inner "$@" || rc=$?
    stage_signal_end
    return "$rc"
}

_intake_run_inner() {
    printf "DEBUG_ENTER _intake_run_inner goal=%s\n" "${ZBUILD_GOAL:-}" >> /tmp/intake_debug.txt
    _INTAKE_RESULT_VERDICT=""
    # ADR-055 §9: resolved up-front, because the closed-issue refusal below
    # returns long before state_dir is derived and must still say why.
    local _intake_art=""
    [[ -n "${2:-}" ]] && _intake_art="$(dirname "${2:-}")/artifacts"
    local _art="${ZBUILD_ARTIFACT_DIR:-}"

    local goal="${ZBUILD_GOAL:-}"
    local issue="${ZBUILD_ISSUE:-0}"
    # #2306 (ADR-070 §2): only an issue has a requirement list; a list left by an
    # earlier run must not be read as this run's.
    local _raw_json="" fetched_ok=""
    [[ -n "$_art" ]] && rm -f "$_art/requirements.json"

    # Support --issue mode: when goal text is absent, derive it from the issue number.
    # Runner exports ZBUILD_GOAL="" in --issue runs, so we fall back rather than hard-fail.
    if [[ -z "$goal" ]]; then
        if [[ -n "$issue" && "$issue" != "0" ]]; then
            # ADR-015 #456: refuse closed issues before fetching body.
            local _state_rc=0
            _intake_check_issue_state "$issue" || _state_rc=$?
            if [[ $_state_rc -ne 0 ]]; then
                # Closed is the operator's choice, not an outage: misconfigured.
                _intake_write_result "$_art" "misconfigured" \
                    "refused issue #$issue — it is not in an actionable state"
                stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "fail" \
                    "refused issue #$issue — it is not in an actionable state" \
                    "No goal was taken in. A closed or locked issue is not work to start."
                return 1
            fi

            # Fetch real title + body from GitHub so the plan stage has context.
            # --jq emits "title\n\nbody" (title-only when body is null/empty).
            # gh failure or empty result → fall back to placeholder + warn so
            # offline/CI runs without auth still complete.
            #
            # Save/restore errexit via $- so callers running with `set +e`
            # don't get -e flipped back on as a side effect.
            local fetched="" gh_rc=0 _had_errexit=0
            [[ $- == *e* ]] && _had_errexit=1
            set +e
            # #491: do NOT redirect run_captured_command's stderr — the
            # command-kind stage-io input banner writes to fd 2 (default
            # ZBUILD_STAGE_IO_FD) and 2>/dev/null would swallow it, breaking
            # the ADR-015 §v4 input-before-action ordering contract.
            # #1729: comments are where an issue is CORRECTED and EXTENDED
            # after filing, and the pipeline was structurally blind to them —
            # shipping half an issue while every gate agreed, because the SPECs
            # the acceptance-gate checks derive from this same goal text.
            #
            # Fetched RAW and filtered locally: the filter is long enough that
            # inlining it as --jq turns into a quoting maze, and a filter that
            # cannot be read is a filter nobody can check.
            local _cmt_max="${ZBUILD_INTAKE_COMMENT_MAX_BYTES:-4000}"
            _raw_json="$(run_captured_command intake gh issue view "$issue" \
                --json title,body,comments)"
            gh_rc=$?
            [[ $_had_errexit -eq 1 ]] && set -e

            if [[ $gh_rc -eq 0 && -n "$_raw_json" ]]; then
                # Author filtering is load-bearing, not tidiness: zbuild posts
                # its own run-completion comments, so an unfiltered append would
                # feed the pipeline its own failure log back as a requirement.
                # Minimized comments are dropped — minimizing is an explicit
                # retraction.
                fetched="$(_intake_compose_goal "$_raw_json" "$_cmt_max" 2>/dev/null || true)"
            fi
            if [[ $gh_rc -eq 0 && -n "$fetched" ]]; then
                # #1729: bound the growth. The goal feeds the redaction
                # chokepoint and every downstream prompt, so an unbounded comment
                # thread inflates every stage.
                local _head="${fetched%%## Additional context from issue comments*}"
                if [[ "$fetched" != "$_head" ]]; then
                    local _cmts="${fetched#*## Additional context from issue comments}"
                    if [[ "${#_cmts}" -gt "$_cmt_max" ]]; then
                        _cmts="${_cmts:0:$_cmt_max}"
                        _cmts="${_cmts}"$'\n\n'"[… issue comments truncated at ${_cmt_max}B — read the issue for the full thread]"
                    fi
                    fetched="${_head}## Additional context from issue comments${_cmts}"
                fi
                goal="$fetched"
                fetched_ok=1
            elif [[ "${ZBUILD_INTAKE_ALLOW_PLACEHOLDER:-0}" == "1" ]]; then
                # #1804: still reachable, but only when asked for. An offline
                # smoke run is legitimate — it just has to say so.
                warn "intake_run: gh issue view #${issue} failed (rc=${gh_rc}); using placeholder (ZBUILD_INTAKE_ALLOW_PLACEHOLDER=1)"
                goal="GitHub issue #${issue}"
            else
                # #1804: FAIL CLOSED. This used to warn and set the goal to the
                # literal "GitHub issue #<N>", and the run proceeded — plan,
                # design (up to three cycles), impact, build, test and six review
                # lenses all executing against a goal that says nothing about
                # what to build. Every other intake failure mode is rc=2; this
                # one was the exception, and it produced the most expensive
                # possible way to discover the fetch had failed.
                error "intake_run: could not read issue #${issue} (gh rc=${gh_rc}) and no --goal was supplied — refusing to run against a goal that says nothing about what to build. Supply --goal, or set ZBUILD_INTAKE_ALLOW_PLACEHOLDER=1 for an offline smoke run."
                # disposition-ok: GitHub (gh issue view) is not responding
                _intake_write_result "$_art" "unavailable" \
                    "could not read issue #${issue} from GitHub (gh rc=${gh_rc}) and no goal was supplied"
                return 1
            fi
        else
            error "intake_run: ZBUILD_GOAL is required (or pass --issue <N>)"
            _intake_write_result "$_art" "misconfigured" \
                "ZBUILD_GOAL is required (or pass --issue <N>)"
            return 1
        fi
    fi

    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "intake_run: state_file argument required"
        _intake_write_result "$_art" "broken" \
            "the engine dispatched this stage with no state file"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/intake-summary.md}" "intake" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 1
    fi
    local state_dir; state_dir="$(dirname "$state_file")"

    local sanitized
    sanitized="$(_intake_strip_synthesized "$goal")"
    if [[ -z "$sanitized" ]]; then
        error "intake_run: goal empty after sentinel sanitization"
        # The input is empty, not zBuild: misconfigured.
        _intake_write_result "$_art" "misconfigured" \
            "the goal was empty after sentinel sanitization"
        stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "fail" \
            "the goal was empty after sanitization, so there is nothing to plan" \
            "No goal was taken in. Every downstream stage would have had no subject."
        return 1
    fi

    # Read detected platforms (written by core/detect/platforms.sh before intake runs)
    local platforms=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && platforms+=("$p")
    done < <(jq -r '.detected[]' "$state_dir/platforms.json" 2>/dev/null || true)
    [[ ${#platforms[@]} -eq 0 ]] && platforms=("generic")

    # Build scope-manifest: one "+ <platform>/" line per platform.
    # Validate platform IDs to ^[a-z0-9_-]+$ before writing — platform values
    # come from plugin manifests / .zbuild/platforms.json and are not fully
    # trusted; malicious values could expand the redaction allowlist via path
    # injection. Use printf '%s' (not '%b') to prevent backslash interpretation.
    {
        local p
        for p in "${platforms[@]}"; do
            if [[ "$p" == "generic" ]]; then
                printf '+ ./\n'
            elif [[ "$p" =~ ^[a-z0-9_-]+$ ]]; then
                printf '+ %s/\n' "$p"
            else
                warn "intake_run: skipping invalid platform id: $p"
            fi
        done
    } | atomic_write "$state_dir/scope-manifest.md"
    local _sm_aw_rc="${PIPESTATUS[1]}"
    if (( _sm_aw_rc != 0 )); then
        _intake_write_result "$_art" "broken" \
            "failed to write scope-manifest.md" || true
        return 1
    fi
    printf '%s\n' "$sanitized"   | atomic_write "$state_dir/intake.md"
    printf "DEBUG_PIPE PIPESTATUS_BEFORE_LOCAL=(%s)\n" "${PIPESTATUS[*]:-}" >> /tmp/intake_debug.txt
    local _im_aw_rc="${PIPESTATUS[1]}"
    printf "DEBUG_LOCAL _im_aw_rc=%s\n" "$_im_aw_rc" >> /tmp/intake_debug.txt
    if (( _im_aw_rc != 0 )); then
        _intake_write_result "$_art" "broken" \
            "failed to write intake.md" || true
        return 1
    fi

    local _title_line
    _title_line="${sanitized%%$'\n'*}"

    # #2306 (ADR-070 §1): the issue's requirements, numbered by the engine.
    if [[ -n "$fetched_ok" && -n "$_art" ]] && ! _intake_write_requirements "$_art" "$_raw_json"; then
        warn "intake_run: could not write $_art/requirements.json — later stages judge the issue text alone"
    fi

    # #2364: the result carries the issue text, so a later stage finds it by
    # what it is (data.issue_text), never by intake's file name.
    _intake_write_result "$_art" "pass" \
        "took in the goal for issue #$issue: ${_title_line:0:60}" \
        "$(jq -nc --arg t "$sanitized" --argjson n "${#platforms[@]}" \
            '{goal_len: ($t | length), platform_count: $n, issue_text: $t}')" || return 1
    stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "pass" \
        "took in the goal for issue #$issue: ${_title_line:0:60}" \
        "$(printf -- '- goal length: %s chars\n- platforms: %s' "${#sanitized}" "${#platforms[@]}")"
    emit_event "plugin.result" "plugin=intake" \
        "goal_len=${#sanitized}" \
        "platform_count=${#platforms[@]}"
    return 0
}
