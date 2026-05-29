#!/usr/bin/env bash
# plugins/agent/intake — Phase 0.5 stub (issue #85)
# Captures goal, sanitizes sentinels, reads platforms.json, writes
# state/scope-manifest.md + state/intake.md. No LLM call this phase.

[[ -n "${_ZBUILD_INTAKE_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_INTAKE_DIR="$_ZBUILD_PLUGIN_DIR"
_INTAKE_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_INTAKE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/output/stage-io.sh
source "$_INTAKE_ROOT/core/output/stage-io.sh"

# ─── Goal sanitization (ported verbatim from legacy/scripts/lib/goal-sanitize.sh)
# Bash 3.2 safe: %% operator only, no regex, no associative arrays.
_intake_strip_synthesized() {
    local _s="$1"

    # Strip prefix form first (KNOWN FIX prepended with blank line after)
    if [[ "$_s" == "KNOWN FIX (from past success):"* ]]; then
        _s="${_s#*$'\n\n'}"
    fi

    # Strip all suffix sentinels
    _s="${_s%%$'\n\n## Plan Summary'*}"
    _s="${_s%%$'\n\n## Key Design Decisions'*}"
    _s="${_s%%$'\n\nIMPORTANT (TDD mode)'*}"
    _s="${_s%%$'\n\nHistorical context'*}"
    _s="${_s%%$'\n\nDiscoveries from'*}"
    _s="${_s%%$'\n\nFile hotspots'*}"
    _s="${_s%%$'\n\nActive security alerts'*}"
    _s="${_s%%$'\n\nCoverage baseline'*}"
    _s="${_s%%$'\n\n## Skill Guidance'*}"
    _s="${_s%%$'\n\n## Historical Build Context'*}"
    _s="${_s%%$'\n\nBLOCKING ISSUES'*}"
    _s="${_s%%$'\n\nIMPORTANT — Previous build'*}"
    _s="${_s%%$'\n\nIMPORTANT — Code review'*}"
    _s="${_s%%$'\n\nIMPORTANT — Architecture'*}"
    _s="${_s%%$'\n\nIMPORTANT — Compound quality'*}"
    _s="${_s%%$'\n\nHUMAN FEEDBACK'*}"
    _s="${_s%%$'\n\n## Previous Session Context'*}"
    _s="${_s%%$'\n\nWARNING: Memory system'*}"

    printf '%s' "$_s"
}

# ─── Closed-issue gate (ADR-015 #456) ───────────────────────────────────────
# Refuse pipeline runs against CLOSED GitHub issues unless the operator
# explicitly overrides via ZBUILD_ALLOW_CLOSED_ISSUE=1 (strict =1, no =true,
# matching the ZBUILD_SCOPE_OVERRIDE convention at core/router/route.sh).
#
# Returns:
#   0 — OPEN, or gh state-check failed (fall through to existing #421 path),
#       or override set
#   2 — CLOSED and no override
_intake_check_issue_state() {
    local issue="$1"
    [[ -z "$issue" || "$issue" == "0" ]] && return 0

    # Save/restore errexit so callers running with `set -e` aren't broken
    # if gh exits non-zero.
    local state_pair="" gh_rc=0 _had_errexit=0
    [[ $- == *e* ]] && _had_errexit=1
    set +e
    state_pair="$(gh issue view "$issue" --json state,stateReason \
        --jq '(.state // "") + "|" + (.stateReason // "")' 2>/dev/null)"
    gh_rc=$?
    [[ $_had_errexit -eq 1 ]] && set -e

    # gh failure or empty: don't block; fall through to the title+body fetch
    # which has its own graceful fallback (#421). Test: T_456_i.
    [[ $gh_rc -ne 0 || -z "$state_pair" ]] && return 0

    local state state_reason
    state="${state_pair%%|*}"
    state_reason="${state_pair#*|}"
    # If no '|' was in the pair (jq returned just one half) treat as empty.
    [[ "$state_reason" == "$state_pair" ]] && state_reason=""

    [[ "$state" != "CLOSED" ]] && return 0

    # CLOSED — check override (strict =1 per ZBUILD_SCOPE_OVERRIDE convention).
    if [[ "${ZBUILD_ALLOW_CLOSED_ISSUE:-0}" == "1" ]]; then
        warn "intake: issue #${issue} is CLOSED (reason: ${state_reason:-<not specified>}); proceeding due to ZBUILD_ALLOW_CLOSED_ISSUE=1"
        emit_event "intake.override.closed_issue_allowed" \
            "plugin=intake" \
            "issue=${issue}" \
            "state=CLOSED" \
            "state_reason=${state_reason:-}"
        return 0
    fi

    # Refuse — derive issue URL when possible; if `gh repo view` fails,
    # omit the URL rather than emit a malformed token. Test: T_456_j.
    local repo_slug="" url_suffix=""
    local _h2=0
    [[ $- == *e* ]] && _h2=1
    set +e
    repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
    [[ $? -ne 0 ]] && repo_slug=""
    [[ $_h2 -eq 1 ]] && set -e
    [[ -n "$repo_slug" ]] && url_suffix=" (https://github.com/${repo_slug}/issues/${issue})"

    error "intake: refusing to build closed issue #${issue}${url_suffix}: state=CLOSED reason=${state_reason:-<not specified>}. Set ZBUILD_ALLOW_CLOSED_ISSUE=1 to override."
    emit_event "intake.refused.issue_closed" \
        "plugin=intake" \
        "issue=${issue}" \
        "state=CLOSED" \
        "state_reason=${state_reason:-}" \
        "repo=${repo_slug:-}"
    return 2
}

# ─── init ────────────────────────────────────────────────────────────────────
intake_init() {
    export ZBUILD_PLUGIN="intake"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=intake"
    return 0
}

# ─── run ─────────────────────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
# Reads: ZBUILD_GOAL (env), ZBUILD_ISSUE (env, optional)
# Writes: $(dirname $state_file)/scope-manifest.md
#         $(dirname $state_file)/intake.md
intake_run() {
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
            fetched="$(run_captured_command intake gh issue view "$issue" \
                --json title,body \
                --jq '(.title // "") as $t
                      | (.body  // "") as $b
                      | if ($t | length) == 0 then ""
                        elif ($b | length) == 0 then $t
                        else $t + "\n\n" + $b
                        end' 2>/dev/null)"
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

    emit_event "plugin.run.complete" "plugin=intake" \
        "goal_len=${#sanitized}" \
        "platform_count=${#platforms[@]}"
    return 0
}

# ─── finalize ────────────────────────────────────────────────────────────────
intake_finalize() {
    emit_event "plugin.finalize.complete" "plugin=intake"
    return 0
}
