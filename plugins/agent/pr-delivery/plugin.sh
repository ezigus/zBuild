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

# Write a v2 result envelope atomically.
_pr_delivery_write_result() {
    local out="$1" verdict="$2" disposition="$3" reason="$4" data_json="${5:-}"
    [[ -z "$data_json" ]] && data_json="{}"
    jq -nc \
        --arg verdict "$verdict" \
        --arg disposition "$disposition" \
        --arg reason "$reason" \
        --argjson data "$data_json" \
        '{"result_contract":2,"verdict":$verdict,"disposition":$disposition,"reason":$reason,"data":$data}' \
        | atomic_write "$out"
}

# Delegate to the merge plugin; write pr-result.json on failure if not already written.
_pr_delivery_merge_delegation() {
    local state_file="$1" artifacts_dir="$2" pr_result_out="$3" policy_name="$4"
    local merge_plugin="$_PR_ROOT/plugins/tool/merge/plugin.sh"
    [[ -f "$merge_plugin" ]] || return 1
    # shellcheck source=../../tool/merge/plugin.sh
    source "$merge_plugin"
    type merge_run >/dev/null 2>&1 || return 1
    local _rc=0
    merge_run "pr" "$state_file" || _rc=$?
    if [[ $_rc -ne 0 ]]; then
        if [[ ! -f "$pr_result_out" ]]; then
            local _mdisp="" _mreason=""
            local _mrf="$artifacts_dir/merge-result.json"
            if [[ -f "$_mrf" ]]; then
                _mdisp="$(jq -r '.disposition // empty' "$_mrf" 2>/dev/null || true)"
                _mreason="$(jq -r '.reason // empty' "$_mrf" 2>/dev/null || true)"
            fi
            _pr_delivery_write_result "$pr_result_out" "error" \
                "${_mdisp:-unavailable}" \
                "${_mreason:-merge delegation failed (rc=$_rc)}"
        fi
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
            "delegated to the merge stage, which did not complete (rc=$_rc)" \
            "No PR was delivered. See the merge stage-summary.md for why."
        return 1
    fi
    stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
        "delivered the change by delegating to the merge stage (policy: $policy_name)" \
        "See the merge stage-summary.md for the result."
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
pr_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "pr_stage_run: state_file argument required"
        local _art_dir="${ZBUILD_ARTIFACT_DIR:-}"
        stage_summary_write "${_art_dir:+${_art_dir}/pr-delivery-summary.md}" "pr-delivery" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        if [[ -n "$_art_dir" ]]; then
            mkdir -p "$_art_dir"
            _pr_delivery_write_result "$_art_dir/pr-result.json" \
                "error" "misconfigured" "state_file argument missing"
        fi
        return 1
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

    # SIGTERM/SIGINT trap: write interrupted result and exit 1.
    # Not via $() so PPID inside subcommands is this process (needed for signal delivery).
    trap '_pr_delivery_write_result "$pr_result_out" "error" "interrupted" "signal received"; exit 1' SIGTERM SIGINT

    # Refuse to open PR if review verdict is block
    if [[ -f "$review_json" ]]; then
        local verdict
        verdict="$(jq -r '.verdict // empty' "$review_json" 2>/dev/null || true)"
        if [[ "$verdict" == "block" ]]; then
            warn "pr: review verdict=block — refusing PR open"
            _pr_delivery_write_result "$pr_result_out" "error" "complete" \
                "refused to open a PR: the review verdict is block"
            stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                "refused to open a PR: the review verdict is block" \
                "No PR was delivered. The review stage judged the change not ready."
            trap - SIGTERM SIGINT
            return 1
        fi
    fi

    # Dry-run mode: write sentinel artifacts without calling gh
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        local _dry_draft="${_TPL_PR_DRAFT:-false}"
        [[ "$_dry_draft" == "true" ]] || _dry_draft="false"
        local _dry_branch="${ZBUILD_BRANCH:-unknown}"
        printf 'https://github.com/mock/repo/pull/0\n' | atomic_write "$pr_url_out"
        local _dry_data
        _dry_data="$(jq -nc \
            --arg branch "$_dry_branch" \
            --arg draft "$_dry_draft" \
            '{"branch":$branch,"pr_number":0,"draft":$draft}')"
        _pr_delivery_write_result "$pr_result_out" "pass" "complete" "dry run" "$_dry_data"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "skip" \
            "dry run — no PR was opened and gh was not called" \
            "Nothing was delivered. This verdict asserts nothing about a real PR."
        trap - SIGTERM SIGINT
        return 0
    fi

    # Resolve declared inputs from ZBUILD_STAGE_INPUTS (ADR-055 §1).
    # review.json stays a by-path optional read — it is not a declared manifest input.
    local _auf_gate_json="" _auf_report_json=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -f "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        _auf_gate_json="$(jq -r '.inputs.gate_aggregator_result // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
        _auf_report_json="$(jq -r '.inputs.review_report // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi

    # Auto-merge path (ADR-037 §4 / I9-B #1050): when policy is auto, delegate to
    # the merge plugin which internally handles gate-absent/fail → PR fallback.
    if [[ "${_TPL_MERGE_POLICY:-auto_unless_flagged}" == "auto" ]]; then
        if _pr_delivery_merge_delegation "$state_file" "$artifacts_dir" "$pr_result_out" "auto"; then
            trap - SIGTERM SIGINT
            return 0
        fi
        trap - SIGTERM SIGINT
        return 1
    # Auto-unless-flagged path (ADR-037 §4 / I9-C #1051): auto-merge only when
    # gate passes AND review-report.json merge_readiness is ready or advisory.
    # Absent review-report → fail-closed (fall through to pr_open_run). ADR-001/#358.
    elif [[ "${_TPL_MERGE_POLICY:-auto_unless_flagged}" == "auto_unless_flagged" ]]; then
        local _auf_gate_verdict="" _auf_readiness=""
        if [[ -n "$_auf_gate_json" && -f "$_auf_gate_json" ]]; then
            _auf_gate_verdict="$(jq -r '.verdict // empty' "$_auf_gate_json" 2>/dev/null || true)"
        fi
        local _auf_top_sev=0
        if [[ -n "$_auf_report_json" && -f "$_auf_report_json" ]]; then
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
            if _pr_delivery_merge_delegation "$state_file" "$artifacts_dir" "$pr_result_out" "auto_unless_flagged"; then
                trap - SIGTERM SIGINT
                return 0
            fi
            trap - SIGTERM SIGINT
            return 1
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
                trap - SIGTERM SIGINT
                return 1
            fi
            # #2250: read pr-open's result verdict — rc=0 with verdict≠pass means blocked
            local _pr_open_verdict=""
            if [[ -f "$pr_result_out" ]]; then
                _pr_open_verdict="$(jq -r '.verdict // empty' "$pr_result_out" 2>/dev/null || true)"
            fi
            if [[ "$_pr_open_verdict" != "pass" ]]; then
                _pr_delivery_write_result "$pr_result_out" "error" "complete" \
                    "review_signal_missing"
                stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "error" \
                    "no PR was opened: pr-open returned rc=0 but verdict is blocked (review_signal_missing)" \
                    "No PR was opened. pr-open blocked because no review signal was present (review_signal_missing)."
                trap - SIGTERM SIGINT
                return 1
            fi
            stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
                "delivered the change by delegating to the pr-open stage" \
                "See the pr-open stage-summary.md for the result."
            trap - SIGTERM SIGINT
            return 0
        fi
    fi

    # Fallback: direct gh pr create.
    # gh runs as a direct child (not via $()) so PPID inside gh is this process,
    # ensuring the SIGTERM trap fires in this shell after gh exits.
    local branch="${ZBUILD_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"
    local title="${ZBUILD_ISSUE_TITLE:-"[#${ZBUILD_ISSUE:-0}] Automated PR"}"
    local _fb_draft="${_TPL_PR_DRAFT:-false}"
    [[ "$_fb_draft" == "true" ]] || _fb_draft="false"
    local -a _fb_gh_args=()
    [[ "${_fb_draft}" == "true" ]] && _fb_gh_args+=("--draft")
    _fb_gh_args+=(--title "$title" --body "")

    local _fb_tmp="${artifacts_dir}/.gh-create-out.tmp"
    local _fb_rc=0
    gh pr create "${_fb_gh_args[@]}" > "$_fb_tmp" 2>/dev/null || _fb_rc=$?
    local _fb_content
    _fb_content="$(cat "$_fb_tmp" 2>/dev/null || true)"
    rm -f "$_fb_tmp"

    if [[ $_fb_rc -ne 0 ]]; then
        _pr_delivery_write_result "$pr_result_out" "error" "unavailable" \
            "gh pr create failed"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
            "could not open a PR for branch $branch" \
            "No PR was delivered. The direct gh fallback failed."
        trap - SIGTERM SIGINT
        return 1
    fi

    local pr_url=""
    if [[ "$_fb_content" =~ https://[^[:space:]]+ ]]; then
        pr_url="${BASH_REMATCH[0]}"
    fi
    [[ -z "$pr_url" ]] && pr_url="${_fb_content%%$'\n'*}"

    printf '%s\n' "$pr_url" | atomic_write "$pr_url_out"
    local _fb_data
    _fb_data="$(jq -nc \
        --arg branch "$branch" \
        --arg pr_url "$pr_url" \
        --arg draft "$_fb_draft" \
        '{"branch":$branch,"pr_url":$pr_url,"draft":$draft}')"
    _pr_delivery_write_result "$pr_result_out" "pass" "complete" \
        "opened a PR directly via gh (fallback path)" "$_fb_data"
    stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
        "opened a PR directly via gh (fallback path)" \
        "$(printf -- '- pr: %s\n- branch: %s' "$pr_url" "$branch")"
    trap - SIGTERM SIGINT
}

# ─── cleanup ────────────────────────────────────────────────────────────────
