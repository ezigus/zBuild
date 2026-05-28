#!/usr/bin/env bash
# plugins/tool/pr-open/plugin.sh — PR Open Stage (ADR-013, issue #344)
# Opens a draft PR via `gh pr create --draft`. No LLM. No redaction. T0 tool.
# Safety constraints:
#   - Always opens as --draft (hard-coded; never a non-draft PR)
#   - Refuses if review.json verdict == "block" (rc=2)
#   - Refuses if current branch is main or master (rc=2)
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_PR_OPEN_LOADED:-}" ]] && return 0
_ZBUILD_PR_OPEN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_PR_OPEN_DIR="$_ZBUILD_PLUGIN_DIR"
_PR_OPEN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PR_OPEN_ROOT/core/event-bus/event-bus.sh"

# ─── pr_open_init ────────────────────────────────────────────────────────────
# Sets plugin identity env vars and emits plugin.init.start.
pr_open_init() {
    export ZBUILD_PLUGIN="pr-open"
    export ZBUILD_PLUGIN_KIND="tool"
    emit_event "plugin.init.start" "plugin=pr-open"
    return 0
}

# ─── pr_open_run ─────────────────────────────────────────────────────────────
# Entry point invoked by the pipeline runner.
# Args: $1 = stage_id, $2 = state_file
pr_open_run() {
    local stage_id="${1:-pr}"; : "$stage_id"  # consumed by pipeline runner; unused in body
    local state_file="${2:-}"

    if [[ -z "$state_file" ]]; then
        error "pr_open_run: state_file argument required"
        return 2
    fi

    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    local review_json_path="$artifacts_dir/review.json"
    local output_pr_result_json="$artifacts_dir/pr-result.json"

    # Read issue number from state file
    local issue_num
    issue_num="$(jq -r '.issue // "0"' "$state_file" 2>/dev/null || echo "0")"
    # Strip quotes if the value was stored as a string
    issue_num="${issue_num//\"/}"

    mkdir -p "$artifacts_dir"

    _pr_open_run_inner "$review_json_path" "$state_file" "$output_pr_result_json" "$issue_num"
}

# ─── _pr_open_run_inner ───────────────────────────────────────────────────────
# Inner logic, separated for testability.
# Args:
#   $1 = review_json_path
#   $2 = state_file
#   $3 = output_pr_result_json
#   $4 = issue_num
_pr_open_run_inner() {
    local review_json_path="$1"
    local state_file="$2"
    local output_pr_result_json="$3"
    local issue_num="$4"

    local artifacts_dir; artifacts_dir="$(dirname "$output_pr_result_json")"
    mkdir -p "$artifacts_dir"

    # ── Safety check 1: refuse if on main or master ──────────────────────────
    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
        error "pr_open: refusing to open PR from branch '${current_branch}' — use a feature branch"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=branch_is_main" "branch=${current_branch}"
        jq -n \
            --arg branch "$current_branch" \
            '{"schema_version":1,"status":"error","reason":("refusing to open PR from branch: "+$branch),"draft":true}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Safety check 2: fail-closed if review.json missing (ADR-001, #358) ───
    if [[ ! -f "$review_json_path" ]]; then
        error "pr_open: refusing to open PR — review.json missing (fail-closed per ADR-001)"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=review_json_missing" "path=${review_json_path}"
        jq -n \
            '{"schema_version":1,"status":"blocked","reason":"review.json missing — fail-closed per ADR-001","draft":true}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Safety check 3: refuse if review verdict == "block" ──────────────────
    local verdict
    verdict="$(jq -r '.verdict // ""' "$review_json_path" 2>/dev/null || echo "")"
    if [[ "$verdict" == "block" ]]; then
        error "pr_open: refusing to open PR — review verdict is 'block'"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=review_verdict_block" "verdict=${verdict}"
        jq -n \
            '{"schema_version":1,"status":"blocked","reason":"review verdict is block","draft":true}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Create/switch to zbuild/issue-N branch ────────────────────────────────
    local target_branch="zbuild/issue-${issue_num}"
    if [[ "$current_branch" != "$target_branch" ]]; then
        git checkout -b "$target_branch" 2>/dev/null || git checkout "$target_branch" 2>/dev/null || {
            error "pr_open: failed to create or switch to branch '${target_branch}'"
            emit_event "plugin.run.error" "plugin=pr-open" \
                "reason=branch_checkout_failed" "branch=${target_branch}"
            jq -n \
                --arg branch "$target_branch" \
                '{"schema_version":1,"status":"error","reason":("failed to checkout branch: "+$branch),"draft":true}' \
                > "$output_pr_result_json"
            return 2
        }
    fi

    # ── Push branch so gh pr create can find it ───────────────────────────────
    if ! git push -u origin "$target_branch" 2>/dev/null; then
        error "pr_open: failed to push branch '${target_branch}' to origin"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=branch_push_failed" "branch=${target_branch}"
        jq -n --arg branch "$target_branch" \
            '{"schema_version":1,"status":"error","reason":("failed to push branch: "+$branch),"draft":true}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Open draft PR via gh ──────────────────────────────────────────────────
    local pr_title
    if [[ -n "$issue_num" && "$issue_num" != "0" ]]; then
        pr_title="zbuild: automated PR for issue #${issue_num}"
    else
        pr_title="zbuild: automated draft PR"
    fi

    # Build PR body from upstream artifacts (plan summary, review verdict, test results)
    local plan_summary="" review_verdict="" test_verdict=""
    if [[ -f "${artifacts_dir}/plan.json" ]]; then
        plan_summary="$(jq -r '.goal // ""' "${artifacts_dir}/plan.json" 2>/dev/null || true)"
    fi
    if [[ -f "$review_json_path" ]]; then
        review_verdict="$(jq -r '.verdict // ""' "$review_json_path" 2>/dev/null || true)"
    fi
    if [[ -f "${artifacts_dir}/test-results.json" ]]; then
        test_verdict="$(jq -r '.verdict // ""' "${artifacts_dir}/test-results.json" 2>/dev/null || true)"
    fi

    local pr_body
    pr_body="$(printf '%s\n\n%s\n%s\n%s\n%s\n%s\n%s' \
        "${issue_num:+Closes #${issue_num}}" \
        "---" \
        "**Plan goal:** ${plan_summary:-N/A}" \
        "**Review verdict:** ${review_verdict:-N/A}" \
        "**Test verdict:** ${test_verdict:-N/A}" \
        "" \
        "Generated by zBuild automation.")"

    local gh_output
    if ! gh_output="$(gh pr create \
        --draft \
        --title "$pr_title" \
        --body "$pr_body" 2>&1)"; then
        error "pr_open: gh pr create failed: $gh_output"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=gh_pr_create_failed"
        jq -n \
            --arg reason "$gh_output" \
            '{"schema_version":1,"status":"error","reason":$reason,"draft":true}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Parse PR URL from gh output ───────────────────────────────────────────
    local pr_url
    pr_url="$(printf '%s' "$gh_output" | grep -Eo 'https://github\.com/[^[:space:]]+' | tail -1 || echo "")"

    if [[ -z "$pr_url" ]]; then
        # gh sometimes outputs the URL as the entire stdout line
        pr_url="$(printf '%s' "$gh_output" | tail -1 | tr -d '[:space:]')"
    fi

    # Extract PR number from URL (last path segment)
    local pr_number
    pr_number="$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || echo "0")"

    # ── Write pr-result.json ──────────────────────────────────────────────────
    # Write canonical pr-url.txt (ADR-013 artifact) and richer pr-result.json
    printf '%s\n' "$pr_url" > "$(dirname "$output_pr_result_json")/pr-url.txt"

    jq -n \
        --argjson schema_version 1 \
        --arg status "opened" \
        --arg pr_url "$pr_url" \
        --argjson pr_number "${pr_number:-0}" \
        --argjson draft true \
        --arg branch "$target_branch" \
        --argjson issue "${issue_num:-0}" \
        '{schema_version: $schema_version, status: $status, pr_url: $pr_url,
          pr_number: $pr_number, draft: $draft, branch: $branch, issue: $issue}' \
        > "$output_pr_result_json"

    emit_event "plugin.run.complete" "plugin=pr-open" \
        "stage=pr" "pr_url=${pr_url}" "pr_number=${pr_number}"
    return 0
}

# ─── pr_open_finalize ─────────────────────────────────────────────────────────
pr_open_finalize() {
    emit_event "plugin.finalize.complete" "plugin=pr-open"
    return 0
}

# ─── pr_open_cleanup ─────────────────────────────────────────────────────────
pr_open_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=pr-open"
    return 0
}
