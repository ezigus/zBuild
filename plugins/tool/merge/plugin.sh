#!/usr/bin/env bash
# plugins/tool/merge/plugin.sh — Auto-Merge Tool (ADR-037 §4, I9-B / #1050)
# Merges the branch via `gh pr merge --squash --auto` when the convergence gate
# passes. Falls back to pr_open_run (draft PR) when gate is absent or != pass.
# Safety constraints:
#   - Refuses if on main/master (rc=2)
#   - Falls back to PR path if gate-aggregator-result.json absent or verdict != pass
#   - Never opens a draft PR on the merge path
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_MERGE_LOADED:-}" ]] && return 0
_ZBUILD_MERGE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_MERGE_DIR="$_ZBUILD_PLUGIN_DIR"
_MERGE_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_MERGE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../scripts/lib/git-remote.sh
source "$_MERGE_ROOT/scripts/lib/git-remote.sh"

# ─── merge_run ───────────────────────────────────────────────────────────────
# Entry point invoked by pr-delivery when _TPL_MERGE_POLICY == auto.
# Args: $1 = stage_id, $2 = state_file
merge_run() {
    local stage_id="${1:-pr}"; : "$stage_id"
    local state_file="${2:-}"

    if [[ -z "$state_file" ]]; then
        error "merge_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/merge-summary.md}" "merge" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 2
    fi

    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local gate_json="$artifacts_dir/gate-aggregator-result.json"
    local merge_result_out="$artifacts_dir/merge-result.json"

    # Read convergence gate verdict
    local gate_verdict=""
    if [[ -f "$gate_json" ]]; then
        gate_verdict="$(jq -r '.verdict // empty' "$gate_json" 2>/dev/null || true)"
    fi

    # Safety guard: fall back to PR when gate absent or verdict != pass
    if [[ "$gate_verdict" != "pass" ]]; then
        local _reason="${gate_verdict:-absent}"
        _merge_pr_fallback "$stage_id" "$state_file" "$merge_result_out" "$_reason"
        return $?
    fi

    # ADR-001/#358 fail-closed: pr-open refuses to publish without a review
    # verdict on disk. Mirror that on the auto-merge path — NEVER auto-merge
    # without review.json. Missing → route to the PR path (which itself
    # fail-closes), so a clean objective gate can't merge an unreviewed branch.
    if [[ ! -f "$artifacts_dir/review.json" ]]; then
        warn "merge_run: review.json absent — fail-closed, routing to PR path (ADR-001/#358)"
        _merge_pr_fallback "$stage_id" "$state_file" "$merge_result_out" "review_absent"
        return $?
    fi

    _merge_run_inner "$stage_id" "$state_file" "$merge_result_out"
    return $?
}

# ─── _merge_pr_fallback ───────────────────────────────────────────────────────
# Gate not pass → delegate to pr_open_run and write merge-result.json=pr_fallback.
_merge_pr_fallback() {
    local stage_id="$1" state_file="$2" merge_result_out="$3" reason="$4"
    local pr_open_plugin="$_MERGE_ROOT/plugins/tool/pr-open/plugin.sh"
    if [[ -f "$pr_open_plugin" ]]; then
        # shellcheck source=../pr-open/plugin.sh
        source "$pr_open_plugin"
    fi
    local _rc=0
    pr_open_run "$stage_id" "$state_file" || _rc=$?
    jq -n \
        --arg reason "$reason" \
        '{"schema_version":1,"status":"pr_fallback","reason":$reason}' \
        > "$merge_result_out"
    return $_rc
}

# ─── _merge_run_inner ─────────────────────────────────────────────────────────
# Gate verdict == pass → checkout branch, push, create non-draft PR, squash-merge.
_merge_run_inner() {
    local stage_id="$1" state_file="$2" merge_result_out="$3"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"

    # Refuse if on main/master
    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
        error "merge_run: refusing to merge from branch '${current_branch}' — use a feature branch"
        stage_summary_write "$artifacts_dir/merge-summary.md" "merge" "error" \
            "refused to merge: already on ${current_branch}" \
            "No merge was attempted; merging from the trunk into itself is never correct."
        emit_event "plugin.result" "verdict=error" "plugin=merge" \
            "reason=branch_is_main" "branch=${current_branch}"
        jq -n --arg branch "$current_branch" \
            '{"schema_version":1,"status":"error","reason":("refusing to merge from: "+$branch)}' \
            > "$merge_result_out"
        return 2
    fi

    local issue_num target_branch
    issue_num="$(jq -r '.issue // "0"' "$state_file" 2>/dev/null || echo "0")"
    issue_num="${issue_num//\"/}"
    target_branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
    if [[ -z "$target_branch" || "$target_branch" == "null" ]]; then
        local _state_dir; _state_dir="$(dirname "$state_file")"
        if [[ -f "$_state_dir/intake-branch.txt" ]]; then
            target_branch="$(head -n1 "$_state_dir/intake-branch.txt" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
    fi
    if [[ -z "$target_branch" ]]; then
        target_branch="zbuild/issue-${issue_num}"
    fi

    # Checkout and push target branch (same plumbing as pr-open)
    if [[ "$current_branch" != "$target_branch" ]]; then
        git checkout -b "$target_branch" 2>/dev/null || git checkout "$target_branch" 2>/dev/null || {
            error "merge_run: failed to checkout branch '${target_branch}'"
            jq -n --arg branch "$target_branch" \
                '{"schema_version":1,"status":"error","reason":("failed to checkout: "+$branch)}' \
                > "$merge_result_out"
            return 2
        }
    fi

    # Reconcile origin/<branch> then push (Issue PR): tolerate already-pushed /
    # diverged remote and surface git's real stderr. The helper's guard also
    # covers the default branch (merge has no main/master guard of its own here).
    if ! zbuild_push_reconcile "$target_branch"; then
        error "merge_run: push reconcile failed for '${target_branch}': ${ZBUILD_PUSH_RECONCILE_ERR}"
        jq -n --arg branch "$target_branch" --arg detail "$ZBUILD_PUSH_RECONCILE_ERR" \
            '{"schema_version":1,"status":"error","reason":("failed to push: "+$branch+": "+$detail)}' \
            > "$merge_result_out"
        return 2
    fi

    local pr_title
    if [[ -n "$issue_num" && "$issue_num" != "0" ]]; then
        pr_title="zbuild: automated merge for issue #${issue_num}"
    else
        pr_title="zbuild: automated merge"
    fi

    # Create non-draft PR then immediately squash-merge. Include a Closes link so
    # the issue auto-closes on merge and the PR isn't flagged as an orphan by the
    # manifest-sync automation (scripts/manifest-sync.sh).
    local pr_body="Auto-merged by zBuild (merge_policy: auto)."
    if [[ -n "$issue_num" && "$issue_num" != "0" ]]; then
        pr_body="${pr_body}"$'\n\n'"Closes #${issue_num}"
    fi
    local gh_output
    if ! gh_output="$(gh pr create \
        --title "$pr_title" \
        --body "$pr_body" 2>&1)"; then
        error "merge_run: gh pr create failed: $gh_output"
        jq -n --arg reason "$gh_output" \
            '{"schema_version":1,"status":"error","reason":$reason}' \
            > "$merge_result_out"
        return 2
    fi

    local pr_url
    pr_url="$(printf '%s' "$gh_output" | grep -Eo 'https://github\.com/[^[:space:]]+' | tail -1 || echo "")"
    [[ -z "$pr_url" ]] && pr_url="$(printf '%s' "$gh_output" | tail -1 | tr -d '[:space:]')"

    local pr_number
    pr_number="$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || echo "0")"

    if ! gh pr merge --squash --auto 2>/dev/null; then
        error "merge_run: gh pr merge failed"
        jq -n --arg pr_url "$pr_url" \
            '{"schema_version":1,"status":"error","reason":"gh pr merge failed","pr_url":$pr_url}' \
            > "$merge_result_out"
        return 2
    fi

    # Write pr-url.txt for downstream compatibility (ADR-013)
    local pr_url_out="$artifacts_dir/pr-url.txt"
    printf '%s\n' "$pr_url" | atomic_write "$pr_url_out"

    jq -n \
        --argjson schema_version 1 \
        --arg status "merged" \
        --arg pr_url "$pr_url" \
        --argjson pr_number "${pr_number:-0}" \
        --arg branch "$target_branch" \
        --argjson issue "${issue_num:-0}" \
        '{"schema_version":$schema_version,"status":$status,"pr_url":$pr_url,
          "pr_number":$pr_number,"branch":$branch,"issue":$issue}' \
        > "$merge_result_out"

    # Manifest contract: pr-delivery declares pr-result.json as a REQUIRED output
    # (plugins/agent/pr-delivery/manifest.yaml). The auto-merge path must write it
    # too (mirror pr-open's schema, status=merged, draft=false) so the pr stage's
    # scan_plugin_outputs check is satisfied — the PR was created then squash-merged.
    local pr_result_out="$artifacts_dir/pr-result.json"
    jq -n \
        --argjson schema_version 1 \
        --arg status "merged" \
        --arg pr_url "$pr_url" \
        --argjson pr_number "${pr_number:-0}" \
        --argjson draft false \
        --arg branch "$target_branch" \
        --argjson issue "${issue_num:-0}" \
        '{schema_version: $schema_version, status: $status, pr_url: $pr_url,
          pr_number: $pr_number, draft: $draft, branch: $branch, issue: $issue}' \
        > "$pr_result_out"

    stage_summary_write "$artifacts_dir/merge-summary.md" "merge" "pass" \
        "merged PR ${pr_number}" \
        "$(printf -- '- pr: %s' "${pr_url}")"
    emit_event "plugin.result" "plugin=merge" \
        "stage=pr" "pr_url=${pr_url}" "pr_number=${pr_number}"
    return 0
}

# ─── merge_cleanup ───────────────────────────────────────────────────────────
