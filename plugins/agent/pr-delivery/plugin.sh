#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/pr — PR delivery agent (issue #756)                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: pr (ADR-013 T2, ADR-018 Pattern 1 — one-shot)
# Produces: state/artifacts/pr-url.txt (canonical), pr-result.json (secondary)
#
# Lifecycle:
#   pr_stage_run        — derive paths, delegate to _pr_stage_run_inner
#   _pr_stage_run_inner — read review.json verdict guard, write artifacts
#   pr_stage_cleanup    — no-op
#
# legacy-citation: pipeline-stages-delivery.sh:81 (stage_pr)

[[ -n "${_ZBUILD_PR_LOADED:-}" ]] && return 0
_ZBUILD_PR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_PR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_PR_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PR_ROOT/core/event-bus/event-bus.sh"

# ─── run ────────────────────────────────────────────────────────────────────
pr_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "pr_stage_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/pr-delivery-summary.md}" "pr-delivery" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 2
    fi
    # Thread the real state_file through — pr-open reads .issue from it, and the
    # runner passes it as $2, NOT via ZBUILD_STATE_FILE (which is unset here).
    _pr_stage_run_inner "$state_file"
}

# ADR-018 Pattern 1 (one-shot): verdict guard → dry-run/pr-open → done.
_pr_stage_run_inner() {
    local state_file="$1"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"
    local review_json="$artifacts_dir/review.json"
    local pr_url_out="$artifacts_dir/pr-url.txt"
    local pr_result_out="$artifacts_dir/pr-result.json"

    # Refuse to open PR if review verdict is block
    if [[ -f "$review_json" ]]; then
        local verdict
        verdict="$(jq -r '.verdict // empty' "$review_json" 2>/dev/null || true)"
        if [[ "$verdict" == "block" ]]; then
            warn "pr: review verdict=block — refusing PR open"
            printf '{"status":"blocked","verdict":"block","branch":"%s"}\n' \
                "${ZBUILD_BRANCH:-unknown}" > "$pr_result_out"
            stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                "refused to open a PR: the review verdict is block" \
                "No PR was delivered. The review stage judged the change not ready."
            return 1
        fi
    fi

    # Dry-run mode: write sentinel artifacts without calling gh
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        local _dry_draft="${_TPL_PR_DRAFT:-false}"
        [[ "$_dry_draft" == "true" ]] || _dry_draft="false"
        printf 'https://github.com/mock/repo/pull/0\n' | atomic_write "$pr_url_out"
        jq -nc --arg branch "${ZBUILD_BRANCH:-unknown}" --argjson draft "$_dry_draft" \
            '{status:"dry_run",branch:$branch,pr_number:0,draft:$draft}' \
            | atomic_write "$pr_result_out"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "skip" \
            "dry run — no PR was opened and gh was not called" \
            "Nothing was delivered. This verdict asserts nothing about a real PR."
        return 0
    fi

    # Auto-merge path (ADR-037 §4 / I9-B #1050): when policy is auto, delegate to
    # the merge plugin which internally handles gate-absent/fail → PR fallback.
    if [[ "${_TPL_MERGE_POLICY:-auto_unless_flagged}" == "auto" ]]; then
        local merge_plugin="$_PR_ROOT/plugins/tool/merge/plugin.sh"
        if [[ -f "$merge_plugin" ]]; then
            # shellcheck source=../../tool/merge/plugin.sh
            source "$merge_plugin"
            if type merge_run >/dev/null 2>&1; then
                local _rc=0
                merge_run "pr" "$state_file" || _rc=$?
                if [[ $_rc -ne 0 ]]; then
                    stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                        "delegated to the merge stage, which did not complete (rc=$_rc)" \
                        "No PR was delivered. See the merge stage-summary.md for why."
                    return "$_rc"
                fi
                stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
                    "delivered the change by delegating to the merge stage (policy: auto)" \
                    "See the merge stage-summary.md for the result."
                return 0
            fi
        fi
    # Auto-unless-flagged path (ADR-037 §4 / I9-C #1051): auto-merge only when
    # gate passes AND review-report.json merge_readiness is ready or advisory.
    # Absent review-report → fail-closed (fall through to pr_open_run). ADR-001/#358.
    elif [[ "${_TPL_MERGE_POLICY:-auto_unless_flagged}" == "auto_unless_flagged" ]]; then
        local _auf_gate_json="$artifacts_dir/gate-aggregator-result.json"
        local _auf_report_json="$artifacts_dir/review-report.json"
        local _auf_gate_verdict="" _auf_readiness=""
        if [[ -f "$_auf_gate_json" ]]; then
            _auf_gate_verdict="$(jq -r '.verdict // empty' "$_auf_gate_json" 2>/dev/null || true)"
        fi
        local _auf_top_sev=0
        if [[ -f "$_auf_report_json" ]]; then
            _auf_readiness="$(jq -r '.merge_readiness // empty' "$_auf_report_json" 2>/dev/null || true)"
            # DoD #1051: escalate on ANY top-severity (critical/high) finding, even
            # if readiness is advisory. The aggregator (lenses.sh) forces
            # needs_attention only on `critical` or a low lens score, so a `high`
            # finding would otherwise slip through as advisory and auto-merge.
            _auf_top_sev="$(jq '[.findings[]? | select(.severity == "critical" or .severity == "high")] | length' "$_auf_report_json" 2>/dev/null || echo 0)"
            [[ "$_auf_top_sev" =~ ^[0-9]+$ ]] || _auf_top_sev=0
        fi
        if [[ "$_auf_gate_verdict" == "pass" && "$_auf_top_sev" -eq 0 && \
              ( "$_auf_readiness" == "ready" || "$_auf_readiness" == "advisory" ) ]]; then
            local merge_plugin="$_PR_ROOT/plugins/tool/merge/plugin.sh"
            if [[ -f "$merge_plugin" ]]; then
                # shellcheck source=../../tool/merge/plugin.sh
                source "$merge_plugin"
                if type merge_run >/dev/null 2>&1; then
                    local _rc=0
                    merge_run "pr" "$state_file" || _rc=$?
                    if [[ $_rc -ne 0 ]]; then
                        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                            "delegated to the merge stage, which did not complete (rc=$_rc)" \
                            "No PR was delivered. See the merge stage-summary.md for why."
                        return "$_rc"
                    fi
                    stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
                        "delivered the change by delegating to the merge stage (policy: auto_unless_flagged)" \
                        "See the merge stage-summary.md for the result."
                    return 0
                fi
            fi
        fi
        # Conditions not met → fall through to pr_open_run (no merge-result.json written)
    fi

    # Invoke pr-open tool plugin via the plugin registry
    local pr_open_plugin="$_PR_ROOT/plugins/tool/pr-open/plugin.sh"
    if [[ -f "$pr_open_plugin" ]]; then
        # shellcheck source=../../tool/pr-open/plugin.sh
        source "$pr_open_plugin"
        if type pr_open_run >/dev/null 2>&1; then
            local _rc=0
            pr_open_run "pr" "$state_file" || _rc=$?
            if [[ $_rc -ne 0 ]]; then
                stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                    "delegated to the pr-open stage, which did not complete (rc=$_rc)" \
                    "No PR was delivered. See the pr-open stage-summary.md for why."
                return "$_rc"
            fi
            stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
                "delivered the change by delegating to the pr-open stage" \
                "See the pr-open stage-summary.md for the result."
            return 0
        fi
    fi

    # Fallback: direct gh pr create
    local branch="${ZBUILD_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"
    local title="${ZBUILD_ISSUE_TITLE:-"[#${ZBUILD_ISSUE:-0}] Automated PR"}"
    local _fb_draft="${_TPL_PR_DRAFT:-false}"
    [[ "$_fb_draft" == "true" ]] || _fb_draft="false"
    local -a _fb_gh_args=()
    [[ "${_fb_draft}" == "true" ]] && _fb_gh_args+=("--draft")
    _fb_gh_args+=(--title "$title" --body "")
    local pr_url
    if pr_url="$(gh pr create "${_fb_gh_args[@]}" 2>/dev/null)"; then
        printf '%s\n' "$pr_url" | atomic_write "$pr_url_out"
        # jq-safe: pr_url/branch may contain characters that would corrupt a
        # printf-built JSON string.
        jq -nc --arg branch "$branch" --arg pr_url "$pr_url" --argjson draft "$_fb_draft" \
            '{status:"opened",branch:$branch,pr_url:$pr_url,draft:$draft}' \
            | atomic_write "$pr_result_out"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
            "opened a PR directly via gh (fallback path)" \
            "$(printf -- '- pr: %s\n- branch: %s' "$pr_url" "$branch")"
    else
        jq -nc --arg branch "$branch" '{status:"error",branch:$branch}' | atomic_write "$pr_result_out"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
            "could not open a PR for branch $branch" \
            "No PR was delivered. The direct gh fallback failed."
        return 1
    fi
}

# ─── cleanup ────────────────────────────────────────────────────────────────
