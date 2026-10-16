#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/pr — PR delivery agent (issue #756)                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: pr (ADR-013 T2, ADR-018 Pattern 1 — one-shot)
# Produces: pr-result.json (the v2 result; primary, ADR-054 §5), pr-url.txt
#
# Lifecycle:
#   pr_stage_run        — derive paths, delegate to _pr_stage_run_inner
#   _pr_stage_run_inner — merge (policy auto / auto_unless_flagged) or pr-open,
#                         then write the v2 result. The review never blocks
#                         (ADR-040 §4); no cleanup hook (nothing held open).
#
# legacy-citation: pipeline-stages-delivery.sh:81 (stage_pr)

[[ -n "${_ZBUILD_PR_LOADED:-}" ]] && return 0
_ZBUILD_PR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
# shellcheck source=../../../scripts/lib/stage-signal.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-signal.sh"
_PR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_PR_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PR_ROOT/core/event-bus/event-bus.sh"
# #2366 (ADR-054 §6): the one writer of a contract-3 result.
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_PR_ROOT/scripts/lib/stage-result.sh"

# ─── result helpers ──────────────────────────────────────────────────────────
_PR_DELIVERY_ARTIFACTS_DIR=""

# _pr_delivery_write_result <artifacts_dir> <outcome> <reason> [pr_url]
# Contract 3 (#2366, ADR-054 §6): one outcome; branch, PR URL and draft ride
# under data.
_pr_delivery_write_result() {
    local _out_dir="$1" _outcome="$2" _reason="${3:-}" _pr_url="${4:-}"
    local _draft="${_TPL_PR_DRAFT:-false}"
    [[ "$_draft" == "true" ]] || _draft="false"
    [[ -z "$_out_dir" ]] && return 1
    stage_result_write "${_out_dir}/pr-result.json" "$_outcome" "$_reason" \
        "$(jq -nc --arg pr_url "$_pr_url" --argjson draft "$_draft" \
            --arg branch "${ZBUILD_BRANCH:-unknown}" \
            '{branch:$branch, pr_url:$pr_url, draft:$draft}')"
}

# _pr_delivery_delegate_ending <result.json> — how a delegate (merge, pr-open)
# that returned non-zero ended: its outcome. Anything that is not a way of
# failing to finish is `unavailable`.
_pr_delivery_delegate_ending() {
    local w=""
    [[ -f "${1:-}" ]] && w="$(jq -r '.outcome // empty' "$1" 2>/dev/null || true)"
    if outcome_is_valid "$w" && [[ "$w" != pass && "$w" != fail ]]; then
        printf '%s' "$w"
    else
        printf 'unavailable'
    fi
}

_pr_delivery_on_signal() {
    local _disp="${1:-interrupted}" _reason="${2:-signal_interrupt}"
    _pr_delivery_write_result "$_PR_DELIVERY_ARTIFACTS_DIR" "$_disp" "$_reason"
    exit 1
}

# ─── run ────────────────────────────────────────────────────────────────────
pr_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "pr_stage_run: state_file argument required"
        _PR_DELIVERY_ARTIFACTS_DIR="${ZBUILD_ARTIFACT_DIR:-}"
        _pr_delivery_write_result "$_PR_DELIVERY_ARTIFACTS_DIR" misconfigured "missing_state_file"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/pr-delivery-summary.md}" \
            "pr-delivery" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
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
    _PR_DELIVERY_ARTIFACTS_DIR="$artifacts_dir"
    local pr_url_out="$artifacts_dir/pr-url.txt"
    local pr_result_out="$artifacts_dir/pr-result.json"

    local _policy="${_TPL_MERGE_POLICY:-auto_unless_flagged}"

    # #2368: the engine says whether every loop that ran passed; anything but
    # "yes" is not a pass.
    local _gate_verdict_early=""
    [[ "${ZBUILD_RUN_LOOPS_PASSED:-}" == "yes" ]] && _gate_verdict_early="pass"

    # ADR-040 §4 (#1844): the review is advisory and never blocks delivery. A
    # report that needs attention keeps auto_unless_flagged from MERGING (below);
    # the change is still delivered as a PR by pr-open.

    # Signal guard over everything that can write a result, the dry run included
    # (#2225 §2, ADR-054 §6a).
    stage_signal_begin _pr_delivery_on_signal

    # Dry-run mode: write sentinel artifacts without calling gh
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        printf 'https://github.com/mock/repo/pull/0\n' | atomic_write "$pr_url_out"
        stage_signal_end
        _pr_delivery_write_result "$artifacts_dir" pass "dry run: no PR opened, gh not called"
        emit_event "pr.delivery.dry_run" "plugin=pr-delivery"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "skip" \
            "dry run — no PR was opened and gh was not called" \
            "Nothing was delivered. This verdict asserts nothing about a real PR."
        return 0
    fi

    # Auto-merge path (ADR-037 §4 / I9-B #1050)
    if [[ "$_policy" == "auto" ]]; then
        local merge_plugin="$_PR_ROOT/plugins/tool/merge/plugin.sh"
        if [[ -f "$merge_plugin" ]]; then
            # shellcheck source=../../tool/merge/plugin.sh
            source "$merge_plugin"
            if type merge_run >/dev/null 2>&1; then
                local _rc=0
                merge_run "pr" "$state_file" || _rc=$?
                if [[ $_rc -ne 0 ]]; then
                    local _m_disp
                    _m_disp="$(_pr_delivery_delegate_ending "${MERGE_RESULT_FILE:-}")"
                    stage_signal_end
                    _pr_delivery_write_result "$artifacts_dir" "$_m_disp" "the merge stage did not complete"
                    stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                        "delegated to the merge stage, which did not complete (rc=$_rc)" \
                        "No PR was delivered. See the merge stage-summary.md for why."
                    return 1
                fi
                stage_signal_end
                _pr_delivery_write_result "$artifacts_dir" pass "merged by the merge stage" \
                    "$(jq -r '.data.pr_url // empty' "${MERGE_RESULT_FILE:-}" 2>/dev/null || true)"
                emit_event "pr.delivery.opened" "plugin=pr-delivery" "via=merge"
                stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
                    "delivered the change by delegating to the merge stage (policy: auto)" \
                    "See the merge stage-summary.md for the result."
                return 0
            fi
        fi
    # Auto-unless-flagged path (ADR-037 §4 / I9-C #1051)
    elif [[ "$_policy" == "auto_unless_flagged" ]]; then
        # #2368: "flagged" is the engine's word — a review lens found a high or
        # critical problem the change introduced (ZBUILD_RUN_FLAGGED=yes). Only an
        # explicit "no" lets it merge: no word at all is not a clean review.
        if [[ "$_gate_verdict_early" == "pass" && "${ZBUILD_RUN_FLAGGED:-}" == "no" ]]; then
            local merge_plugin="$_PR_ROOT/plugins/tool/merge/plugin.sh"
            if [[ -f "$merge_plugin" ]]; then
                # shellcheck source=../../tool/merge/plugin.sh
                source "$merge_plugin"
                if type merge_run >/dev/null 2>&1; then
                    local _rc=0
                    merge_run "pr" "$state_file" || _rc=$?
                    if [[ $_rc -ne 0 ]]; then
                        local _m_disp
                        _m_disp="$(_pr_delivery_delegate_ending "${MERGE_RESULT_FILE:-}")"
                        stage_signal_end
                        _pr_delivery_write_result "$artifacts_dir" "$_m_disp" "the merge stage did not complete"
                        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                            "delegated to the merge stage, which did not complete (rc=$_rc)" \
                            "No PR was delivered. See the merge stage-summary.md for why."
                        return 1
                    fi
                    stage_signal_end
                    _pr_delivery_write_result "$artifacts_dir" pass "merged by the merge stage" \
                        "$(jq -r '.data.pr_url // empty' "${MERGE_RESULT_FILE:-}" 2>/dev/null || true)"
                    emit_event "pr.delivery.opened" "plugin=pr-delivery" "via=merge"
                    stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
                        "delivered the change by delegating to the merge stage (policy: auto_unless_flagged)" \
                        "See the merge stage-summary.md for the result."
                    return 0
                fi
            fi
        fi
        # Conditions not met — fall through to pr_open_run (ADR-001/#358 fail-closed)
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
                local _po_disp
                _po_disp="$(_pr_delivery_delegate_ending "$pr_result_out")"
                stage_signal_end
                _pr_delivery_write_result "$artifacts_dir" "$_po_disp" "the pr-open stage did not complete"
                stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                    "delegated to the pr-open stage, which did not complete (rc=$_rc)" \
                    "No PR was delivered. See the pr-open stage-summary.md for why."
                return 1
            fi
            # #2250: pr-open REFUSES with rc=0 and outcome fail (no review signal
            # — ADR-001 fail-closed). Its outcome says what happened.
            local _po_verdict="" _po_reason=""
            if [[ -s "$pr_result_out" ]]; then
                _po_verdict="$(jq -r '.outcome // empty' "$pr_result_out" 2>/dev/null || true)"
                _po_reason="$(jq -r '.reason // empty' "$pr_result_out" 2>/dev/null || true)"
            fi
            if [[ "$_po_verdict" == "fail" ]]; then
                stage_signal_end
                _pr_delivery_write_result "$artifacts_dir" fail \
                    "pr-open refused to open a PR: ${_po_reason:-no reason given}"
                emit_event "pr.delivery.blocked" "plugin=pr-delivery" "detail=${_po_reason:-blocked}"
                stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
                    "pr-open refused to open a PR: ${_po_reason:-blocked}" \
                    "No PR was opened. See the pr-open stage-summary.md for why."
                emit_event "plugin.result" "verdict=fail" "plugin=pr-delivery" \
                    "reason=pr_open_blocked" "detail=${_po_reason:-blocked}"
                return 1
            fi
            local _po_url=""
            [[ -f "$pr_url_out" ]] && _po_url="$(head -1 "$pr_url_out" 2>/dev/null || true)"
            stage_signal_end
            _pr_delivery_write_result "$artifacts_dir" pass "PR opened by pr-open: ${_po_url:-url not reported}" "$_po_url"
            emit_event "pr.delivery.opened" "plugin=pr-delivery" "via=pr-open"
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
    local pr_url _fb_err="$artifacts_dir/.gh-pr-create.err"
    if pr_url="$(gh pr create "${_fb_gh_args[@]}" 2>"$_fb_err")"; then
        rm -f "$_fb_err"
        printf '%s\n' "$pr_url" | atomic_write "$pr_url_out"
        stage_signal_end
        _pr_delivery_write_result "$artifacts_dir" pass "PR opened directly with gh: $pr_url" "$pr_url"
        emit_event "pr.delivery.opened" "plugin=pr-delivery" "via=gh"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "pass" \
            "opened a PR directly via gh (fallback path)" \
            "$(printf -- '- pr: %s\n- branch: %s' "$pr_url" "$branch")"
        return 0
    else
        stage_signal_end
        # gh's own words, so the failure says what went wrong (review on #2285).
        local _fb_detail; _fb_detail="$(tr '\n' ' ' 2>/dev/null < "$_fb_err" || true)"; rm -f "$_fb_err"
        # disposition-ok: GitHub (gh pr create) is not responding
        _pr_delivery_write_result "$artifacts_dir" unavailable "gh pr create failed: ${_fb_detail:-no error output}"
        stage_summary_write "$artifacts_dir/pr-delivery-summary.md" "pr-delivery" "fail" \
            "could not open a PR for branch $branch" \
            "No PR was delivered. The direct gh fallback failed."
        return 1
    fi
}

# ─── cleanup ────────────────────────────────────────────────────────────────
