#!/usr/bin/env bash
# plugins/agent/intake — Phase 0.5 stub (issue #85)
# Captures goal, sanitizes sentinels, reads platforms.json, writes
# state/scope-manifest.md + state/intake.md. No LLM call this phase.

[[ -n "${_ZBUILD_INTAKE_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
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
# shellcheck source=lib/branch-names.sh
source "$_INTAKE_DIR/lib/branch-names.sh"
# shellcheck source=lib/branch-ops.sh
source "$_INTAKE_DIR/lib/branch-ops.sh"

# ─── run ─────────────────────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
# Reads: ZBUILD_GOAL (env), ZBUILD_ISSUE (env, optional)
# Writes: $(dirname $state_file)/scope-manifest.md
#         $(dirname $state_file)/intake.md
intake_run() {
    # ADR-055 §9: resolved up-front, because the closed-issue refusal below
    # returns long before state_dir is derived and must still say why.
    local _intake_art=""
    [[ -n "${2:-}" ]] && _intake_art="$(dirname "${2:-}")/artifacts"
    local goal="${ZBUILD_GOAL:-}"
    local issue="${ZBUILD_ISSUE:-0}"

    # Support --issue mode: when goal text is absent, derive it from the issue number.
    # Runner exports ZBUILD_GOAL="" in --issue runs, so we fall back rather than hard-fail.
    if [[ -z "$goal" ]]; then
        if [[ -n "$issue" && "$issue" != "0" ]]; then
            # ADR-015 #456: refuse closed issues before fetching body.
            local _state_rc=0
            _intake_check_issue_state "$issue" || _state_rc=$?
            if [[ $_state_rc -ne 0 ]]; then
                stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "fail" \
                    "refused issue #$issue — it is not in an actionable state" \
                    "No goal was taken in. A closed or locked issue is not work to start."
                return $_state_rc
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
            fetched="$(run_captured_command intake gh issue view "$issue" \
                --json title,body \
                --jq '(.title // "") as $t
                      | (.body  // "") as $b
                      | if ($t | length) == 0 then ""
                        elif ($b | length) == 0 then $t
                        else $t + "\n\n" + $b
                        end')"
            gh_rc=$?
            [[ $_had_errexit -eq 1 ]] && set -e
            if [[ $gh_rc -eq 0 && -n "$fetched" ]]; then
                goal="$fetched"
            else
                warn "intake_run: gh issue view #${issue} failed (rc=${gh_rc}); using placeholder"
                goal="GitHub issue #${issue}"
            fi
        else
            error "intake_run: ZBUILD_GOAL is required (or pass --issue <N>)"
            return 2
        fi
    fi

    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "intake_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"

    local sanitized
    sanitized="$(_intake_strip_synthesized "$goal")"
    if [[ -z "$sanitized" ]]; then
        error "intake_run: goal empty after sentinel sanitization"
        stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "fail" \
            "the goal was empty after sanitization, so there is nothing to plan" \
            "No goal was taken in. Every downstream stage would have had no subject."
        return 2
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
    printf '%s\n' "$sanitized"   | atomic_write "$state_dir/intake.md"

    # Issue #484: derive title from first line of sanitized goal for branch slug.
    # Mirrors legacy's `slug=$(echo "$GOAL" | tr ... | sed ... | cut ...)`,
    # but we use the title line (first \n-terminated chunk) so multi-line
    # issue bodies don't bloat the slug. The 40-char cut in _intake_derive
    # provides the same bound legacy:84 used.
    local _title_line
    _title_line="${sanitized%%$'\n'*}"

    # Load state_helpers if available so _set_pipeline_branch can record the
    # branch on the pipeline-state.json. Defer-loaded to avoid hard coupling.
    if ! declare -F _set_pipeline_branch >/dev/null 2>&1; then
        # shellcheck source=../../../core/pipeline/state_helpers.sh
        [[ -f "$_INTAKE_ROOT/core/pipeline/state_helpers.sh" ]] && \
            source "$_INTAKE_ROOT/core/pipeline/state_helpers.sh" 2>/dev/null || true
    fi

    # Branch creation is fail-CLOSED — any refusal propagates as rc=2 so
    # the pipeline halts before downstream stages corrupt main/HEAD. Tests
    # that don't exercise the real git path set ZBUILD_INTAKE_SKIP_BRANCH=1.
    if [[ "${ZBUILD_INTAKE_SKIP_BRANCH:-0}" != "1" ]]; then
        local _branch_rc=0
        _intake_create_workspace_branch "$state_dir" "$issue" "$_title_line" \
            || _branch_rc=$?
        if [[ $_branch_rc -ne 0 ]]; then
            stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "fail" \
                "could not create the workspace branch" \
                "Fail-closed: work does not proceed on the current branch, which may be main."
            return $_branch_rc
        fi
    fi

    stage_summary_write "${_intake_art:+$_intake_art/intake-summary.md}" "intake" "pass" \
        "took in the goal for issue #$issue: ${_title_line:0:60}" \
        "$(printf -- '- goal length: %s chars\n- platforms: %s' "${#sanitized}" "${#platforms[@]}")"
    emit_event "plugin.result" "plugin=intake" \
        "goal_len=${#sanitized}" \
        "platform_count=${#platforms[@]}"
    return 0
}
