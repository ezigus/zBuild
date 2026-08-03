#!/usr/bin/env bash
# Compute and post the claude-code-review outcome comment.
# Called from .github/workflows/claude-code-review.yml "Post review outcome comment".
# Env: GH_TOKEN, PR, GITHUB_REPOSITORY, REVIEW_OUTCOME, RUN_URL

[[ -n "${_CI_REVIEW_OUTCOME_LOADED:-}" ]] && return 0
_CI_REVIEW_OUTCOME_LOADED=1

# The REVIEWER's identity — the account whose comments carry the findings and the
# verdict marker. NOT github-actions[bot], which is the account that posts the
# outcome summary at the bottom of this file. Getting the two backwards makes
# every lookup here return zero and silently reproduces the bug this file exists
# to fix: verified against PR #1679, where a review reporting a real correctness
# regression in a top-level comment scored top_count=0, verdict="".
_REVIEWER_LOGIN="claude[bot]"

# ─── Pure filters — stdin is the raw `gh api` comments JSON ─────────────────
# Split from the fetch so the filter logic is executable, and therefore testable,
# with no network. Stubbing the fetchers wholesale is what hid the wrong-login
# defect from the entire suite on the first pass (see #1694).

filter_top_count() {
    # Reviewer comments only. The outcome summaries are posted by a DIFFERENT
    # account, so filtering on the reviewer excludes them by construction — no
    # body-pattern match needed, which also removes a jq-injection vector.
    jq --arg login "$_REVIEWER_LOGIN" '[.[] | select(.user.login == $login)] | length' 2>/dev/null || echo '?'
}

filter_verdict() {
    # The last reviewer comment that actually CARRIES a marker — not merely the
    # last reviewer comment, which on a re-review may predate the marker.
    jq -r --arg login "$_REVIEWER_LOGIN" \
        '[.[] | select(.user.login == $login) | .body
           | match("<!-- verdict: [a-z]+ -->").string? // empty] | last // ""' 2>/dev/null || true
}

_gh_inline_count() {
    local repo="$1" pr="$2"
    gh api "repos/${repo}/pulls/${pr}/comments" --jq "length" 2>/dev/null || echo '?'
}

_gh_top_count() {
    local repo="$1" pr="$2"
    gh api "repos/${repo}/issues/${pr}/comments" 2>/dev/null | filter_top_count
}

_gh_verdict() {
    local repo="$1" pr="$2"
    gh api "repos/${repo}/issues/${pr}/comments" 2>/dev/null | filter_verdict
}

# Did the reviewer actually RUN? The action skips outright when the workflow file
# differs from the default branch's copy — i.e. on every PR that edits this
# workflow — and the STEP still reports outcome=success. Without this guard the
# summary claims a clean review of a review that never happened; PR #1690 did
# exactly that to itself. The action writes its execution log whenever it runs,
# so absence is the signal.
_reviewer_ran() {
    local exec_file="${RUNNER_TEMP:-/tmp}/claude-execution-output.json"
    [[ -s "$exec_file" ]]
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
    elif ! _reviewer_ran; then
        # No verdict AND no execution log: the action never ran (workflow-validation
        # skip). "No findings" here would be a claim about a review that did not
        # happen — the #1618 failure, one layer up.
        status="⚠️ **Claude review of \`${short}\`: did not run** — the action was skipped (workflow validation), so this is NOT a clean result."
    elif [[ "$n_inline" == '?' || "$n_top" == '?' ]]; then
        # EITHER lookup failing is enough to make a count meaningless. Requiring
        # both to fail let _safe_add coerce the failed side to 0 and report a
        # confident "no findings" built on one successful query.
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
