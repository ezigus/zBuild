#!/usr/bin/env bash
# plugins/agent/intake/lib/issue-state.sh — closed-issue gate (ADR-015 #456)

[[ -n "${_ZBUILD_INTAKE_ISSUE_STATE_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_ISSUE_STATE_LOADED=1

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
