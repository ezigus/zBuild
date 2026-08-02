#!/usr/bin/env bash
# Compute and post the claude-code-review outcome comment.
# Called from .github/workflows/claude-code-review.yml "Post review outcome comment".
# Env: GH_TOKEN, PR, GITHUB_REPOSITORY, REVIEW_OUTCOME, RUN_URL

[[ -n "${_CI_REVIEW_OUTCOME_LOADED:-}" ]] && return 0
_CI_REVIEW_OUTCOME_LOADED=1

# Patterns matching outcome-summary comments this step emits; excluded from reviewer-comment count.
_OUTCOME_BODY_PATTERN="Claude review did not complete|Claude review may be incomplete|Claude review of"

_gh_inline_count() {
    local repo="$1" pr="$2"
    gh api "repos/${repo}/pulls/${pr}/comments" --jq "length" 2>/dev/null || echo '?'
}

_gh_top_count() {
    local repo="$1" pr="$2"
    gh api "repos/${repo}/issues/${pr}/comments" \
        --jq "[.[] | select(.user.login == \"github-actions[bot]\") | select(.body | test(\"${_OUTCOME_BODY_PATTERN}\") | not)] | length" \
        2>/dev/null || echo '?'
}

_gh_verdict() {
    local repo="$1" pr="$2"
    gh api "repos/${repo}/issues/${pr}/comments" \
        --jq '[.[] | select(.user.login == "github-actions[bot]") | .body] | last // ""' \
        2>/dev/null | /usr/bin/grep -o '<!-- verdict: [a-z]* -->' | tail -1 || true
}

_safe_add() {
    local a="$1" b="$2"
    local na=0 nb=0
    [[ "$a" =~ ^[0-9]+$ ]] && na="$a"
    [[ "$b" =~ ^[0-9]+$ ]] && nb="$b"
    echo $(( na + nb ))
}

compute_review_status() {
    local sha="${1:-}"
    local short="${sha:0:7}"

    local exec_file="${RUNNER_TEMP:-/tmp}/claude-execution-output.json"
    local denials=0 is_error=false
    if [[ -f "$exec_file" ]]; then
        denials="$(jq -rs '[.. | objects | select(has("permission_denials_count")) | .permission_denials_count] | last // 0' "$exec_file" 2>/dev/null || echo 0)"
        is_error="$(jq -rs '[.. | objects | select(has("is_error")) | .is_error] | last // false' "$exec_file" 2>/dev/null || echo false)"
    fi
    [[ "$denials" =~ ^[0-9]+$ ]] || denials=0

    local n_inline n_top verdict
    n_inline="$(_gh_inline_count "${GITHUB_REPOSITORY}" "${PR}")"
    n_top="$(_gh_top_count "${GITHUB_REPOSITORY}" "${PR}")"
    verdict="$(_gh_verdict "${GITHUB_REPOSITORY}" "${PR}")"

    local status
    if [[ "${REVIEW_OUTCOME}" != "success" || "$is_error" == "true" ]]; then
        status="❌ **Claude review did not complete** for \`${short}\` — see the run log."
    elif [[ "$denials" -gt 0 ]]; then
        status="⚠️ **Claude review may be incomplete** for \`${short}\` — ${denials} tool-permission denial(s); results may be partial."
    elif [[ "$verdict" == "<!-- verdict: findings -->" ]]; then
        local total; total="$(_safe_add "$n_inline" "$n_top")"
        status="🔎 **Claude review of \`${short}\`: findings posted** (${total} comment(s))."
    elif [[ "$verdict" == "<!-- verdict: clean -->" ]]; then
        status="✅ **Claude review of \`${short}\`: no findings.**"
    elif [[ "$n_inline" == '?' && "$n_top" == '?' ]]; then
        status="⚠️ **Claude review of \`${short}\`: outcome unknown** — could not fetch comment counts."
    else
        local total; total="$(_safe_add "$n_inline" "$n_top")"
        if [[ "$total" -gt 0 ]]; then
            status="🔎 **Claude review of \`${short}\`: ${total} comment(s) posted.**"
        else
            status="✅ **Claude review of \`${short}\`: no findings.**"
        fi
    fi

    echo "$status"
}

post_review_outcome() {
    local sha
    sha="$(gh pr view "${PR}" --repo "${GITHUB_REPOSITORY}" --json headRefOid -q .headRefOid 2>/dev/null || echo '')"
    local short="${sha:0:7}"

    local status
    status="$(compute_review_status "$sha")"

    # shellcheck disable=SC2016
    printf '%s\n\n_Reviewed on push of `%s` · [run log](%s)_\n' \
        "$status" "$short" "${RUN_URL}" | gh pr comment "${PR}" --repo "${GITHUB_REPOSITORY}" --body-file -
}
