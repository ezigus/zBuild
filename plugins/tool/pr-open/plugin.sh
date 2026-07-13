#!/usr/bin/env bash
# plugins/tool/pr-open/plugin.sh — PR Open Stage (ADR-013, issue #344)
# Opens a PR via `gh pr create`. No LLM. No redaction. T0 tool.
# Safety constraints:
#   - Non-draft by default; set _TPL_PR_DRAFT=true (pr_draft: true in template) for draft mode
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
# shellcheck source=../../../scripts/lib/git-remote.sh
source "$_PR_OPEN_ROOT/scripts/lib/git-remote.sh"
# #1265: merge-base resolver for the 0-commit preflight (halt before push/gh).
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_PR_OPEN_ROOT/scripts/lib/merge-base.sh"

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

    # Normalize to a strict JSON boolean literal: only "true" stays true; any
    # other value (unset, empty, or a bogus env-injected string that bypassed
    # the template validator) collapses to "false". Guarantees `--argjson draft`
    # and printf %s never receive non-boolean input.
    local _draft_bool="${_TPL_PR_DRAFT:-false}"
    [[ "$_draft_bool" == "true" ]] || _draft_bool="false"

    # ── Safety check 1: refuse if on main or master ──────────────────────────
    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
        error "pr_open: refusing to open PR from branch '${current_branch}' — use a feature branch"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=branch_is_main" "branch=${current_branch}"
        jq -n \
            --arg branch "$current_branch" \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"error","reason":("refusing to open PR from branch: "+$branch),"draft":$draft}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Safety check 2/3: review verdict source (#1142, ADR-040) ─────────────
    # review.json = the BLOCKING-review model (standard.yaml): apply the verdict
    # guard below (refuse on block). If it is absent, fall back to the advisory
    # review-report.json (simple.yaml's review-aggregator — advisory lenses NEVER
    # block; convergence was already gated by the gate-aggregator's exit_when):
    # open the PR with no verdict guard. Fail-closed (ADR-001/#358) only when
    # NEITHER review signal exists.
    local advisory_report="$artifacts_dir/review-report.json"
    if [[ -f "$review_json_path" ]]; then
        local verdict
        verdict="$(jq -r '.verdict // ""' "$review_json_path" 2>/dev/null || echo "")"
        if [[ "$verdict" == "block" ]]; then
            error "pr_open: refusing to open PR — review verdict is 'block'"
            emit_event "plugin.run.error" "plugin=pr-open" \
                "reason=review_verdict_block" "verdict=${verdict}"
            jq -n \
                --argjson draft "${_draft_bool}" \
                '{"schema_version":1,"status":"blocked","reason":"review verdict is block","draft":$draft}' \
                > "$output_pr_result_json"
            return 2
        fi
    elif [[ -f "$advisory_report" ]]; then
        warn "pr_open: review.json absent — advisory-review mode (review-report.json present; ADR-040 lenses never block, #1142)"
    else
        error "pr_open: refusing to open PR — no review signal (neither review.json nor review-report.json; fail-closed per ADR-001)"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=review_signal_missing" "path=${review_json_path}"
        jq -n \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"blocked","reason":"no review signal — fail-closed per ADR-001","draft":$draft}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Determine target branch ───────────────────────────────────────────────
    # Issue #484: prefer the branch recorded by intake (state.branch or
    # intake-branch.txt) so we use the slug-bearing name intake already
    # created. Fall back to the legacy zbuild/issue-N form so existing
    # state files without a .branch field still work (transitional).
    local target_branch=""
    target_branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
    if [[ -z "$target_branch" || "$target_branch" == "null" ]]; then
        local _state_dir; _state_dir="$(dirname "$state_file")"
        if [[ -f "$_state_dir/intake-branch.txt" ]]; then
            target_branch="$(head -n1 "$_state_dir/intake-branch.txt" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
    fi
    if [[ -z "$target_branch" ]]; then
        target_branch="zbuild/issue-${issue_num}"
        emit_event "plugin.pr_open.branch_fallback_used" \
            "plugin=pr-open" "branch=${target_branch}" "reason=no_state_branch"
    fi
    if [[ "$current_branch" != "$target_branch" ]]; then
        git checkout -b "$target_branch" 2>/dev/null || git checkout "$target_branch" 2>/dev/null || {
            error "pr_open: failed to create or switch to branch '${target_branch}'"
            emit_event "plugin.run.error" "plugin=pr-open" \
                "reason=branch_checkout_failed" "branch=${target_branch}"
            jq -n \
                --arg branch "$target_branch" \
                --argjson draft "${_draft_bool}" \
                '{"schema_version":1,"status":"error","reason":("failed to checkout branch: "+$branch),"draft":$draft}' \
                > "$output_pr_result_json"
            return 2
        }
    fi

    # ── #1265: 0-commit preflight (BEFORE push + gh pr create) ────────────────
    # If the branch has no commits ahead of the merge-base, there is nothing to
    # PR: pushing then `gh pr create` fails with "No commits between main and
    # branch" only AFTER a wasted push (the #1214 dogfood, ~38 min in). Halt
    # terminally here instead. Belt-and-suspenders for non-cycle paths + a clear
    # reason. Consistent with #1208: a legit empty_diff converge with 0 real
    # commits genuinely has nothing to ship, so halting is correct (not a regress).
    local _merge_base _ahead_count
    _merge_base="$(zbuild_resolve_merge_base 2>/dev/null || true)"
    if [[ -n "$_merge_base" ]]; then
        _ahead_count="$(git rev-list --count "${_merge_base}..HEAD" 2>/dev/null || echo -1)"
        if [[ "$_ahead_count" == "0" ]]; then
            error "pr_open: refusing to open PR — no commits between merge-base and '${current_branch}' (nothing to ship)"
            emit_event "plugin.run.error" "plugin=pr-open" \
                "reason=no_committed_changes" "branch=${current_branch}"
            jq -n \
                --argjson draft "${_draft_bool}" \
                '{"schema_version":1,"status":"error","reason":"no committed changes on branch","draft":$draft}' \
                > "$output_pr_result_json"
            return 2
        fi
    fi

    # ── Push branch so gh pr create can find it ───────────────────────────────
    # zbuild_push_reconcile tolerates an already-pushed / diverged remote branch
    # (push / fast-forward / safe force-with-lease) and surfaces git's real
    # stderr in ZBUILD_PUSH_RECONCILE_ERR (Issue PR). It never force-pushes the
    # default branch — that plus the main/master refusal above is defense-in-depth.
    if ! zbuild_push_reconcile "$target_branch"; then
        error "pr_open: push reconcile failed for '${target_branch}': ${ZBUILD_PUSH_RECONCILE_ERR}"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=branch_push_failed" "branch=${target_branch}"
        jq -n --arg branch "$target_branch" --arg detail "$ZBUILD_PUSH_RECONCILE_ERR" \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"error","reason":("failed to push branch: "+$branch+": "+$detail),"draft":$draft}' \
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

    local -a _gh_args=()
    [[ "${_draft_bool}" == "true" ]] && _gh_args+=("--draft")
    _gh_args+=(--title "$pr_title" --body "$pr_body")

    local gh_output
    if ! gh_output="$(gh pr create "${_gh_args[@]}" 2>&1)"; then
        error "pr_open: gh pr create failed: $gh_output"
        emit_event "plugin.run.error" "plugin=pr-open" \
            "reason=gh_pr_create_failed"
        jq -n \
            --arg reason "$gh_output" \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"error","reason":$reason,"draft":$draft}' \
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
    # Write canonical pr-url.txt (ADR-013 artifact) and richer pr-result.json.
    # #507: pr-url.txt is the manifest-declared primary output — written via
    # atomic_write to satisfy the primary-output atomicity guard test.
    printf '%s\n' "$pr_url" | atomic_write "$(dirname "$output_pr_result_json")/pr-url.txt"

    jq -n \
        --argjson schema_version 1 \
        --arg status "opened" \
        --arg pr_url "$pr_url" \
        --argjson pr_number "${pr_number:-0}" \
        --argjson draft "${_draft_bool}" \
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
