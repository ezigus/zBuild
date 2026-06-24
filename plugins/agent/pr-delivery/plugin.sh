#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/pr — PR delivery agent (issue #756)                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: pr (ADR-013 T2, ADR-018 Pattern 1 — one-shot)
# Produces: state/artifacts/pr-url.txt (canonical), pr-result.json (secondary)
#
# Lifecycle:
#   pr_stage_init       — set env vars, emit plugin.run.start
#   pr_stage_run        — derive paths, delegate to _pr_stage_run_inner
#   _pr_stage_run_inner — read review.json verdict guard, write artifacts
#   pr_stage_finalize   — emit plugin.run.complete
#   pr_stage_cleanup    — no-op
#
# legacy-citation: pipeline-stages-delivery.sh:81 (stage_pr)

[[ -n "${_ZBUILD_PR_LOADED:-}" ]] && return 0
_ZBUILD_PR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_PR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_PR_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PR_ROOT/core/event-bus/event-bus.sh"

# ─── init ───────────────────────────────────────────────────────────────────
pr_stage_init() {
    export ZBUILD_PLUGIN="pr-delivery"
    export ZBUILD_PLUGIN_KIND="agent"
    # The framework (plugin_hook_call) emits plugin.run.start/complete; init only
    # emits plugin.init.start, matching the review/build/test_assessment agents.
    emit_event "plugin.init.start" "plugin=pr-delivery"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
pr_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "pr_stage_run: state_file argument required"
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
            return 1
        fi
    fi

    # Dry-run mode: write sentinel artifacts without calling gh
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        printf 'https://github.com/mock/repo/pull/0\n' | atomic_write "$pr_url_out"
        printf '{"status":"dry_run","branch":"%s","pr_number":0,"draft":true}\n' \
            "${ZBUILD_BRANCH:-unknown}" | atomic_write "$pr_result_out"
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
                merge_run "pr" "$state_file" || return $?
                return 0
            fi
        fi
    fi

    # Invoke pr-open tool plugin via the plugin registry
    local pr_open_plugin="$_PR_ROOT/plugins/tool/pr-open/plugin.sh"
    if [[ -f "$pr_open_plugin" ]]; then
        # shellcheck source=../../tool/pr-open/plugin.sh
        source "$pr_open_plugin"
        if type pr_open_run >/dev/null 2>&1; then
            pr_open_run "pr" "$state_file" || return $?
            return 0
        fi
    fi

    # Fallback: direct gh pr create
    local branch="${ZBUILD_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"
    local title="${ZBUILD_ISSUE_TITLE:-"[#${ZBUILD_ISSUE:-0}] Automated PR"}"
    local pr_url
    if pr_url="$(gh pr create --draft --title "$title" --body "" 2>/dev/null)"; then
        printf '%s\n' "$pr_url" | atomic_write "$pr_url_out"
        printf '{"status":"opened","branch":"%s","pr_url":"%s","draft":true}\n' \
            "${branch}" "$pr_url" | atomic_write "$pr_result_out"
    else
        printf '{"status":"error","branch":"%s"}\n' "${branch}" | atomic_write "$pr_result_out"
        return 1
    fi
}

# ─── finalize ───────────────────────────────────────────────────────────────
pr_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=pr-delivery"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
pr_stage_cleanup() {
    return 0
}
