#!/usr/bin/env bash
# plugins/tool/deploy-release — deploy-release executor (kind:tool, T0, issue #757)
# Executes git-tag + gh release create. No LLM calls. Invoked by deploy agent.
# ZBUILD_DRY_RUN=1 writes sentinel deploy-result.json without executing.

[[ -n "${_ZBUILD_DEPLOY_RELEASE_LOADED:-}" ]] && return 0
_ZBUILD_DEPLOY_RELEASE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_DR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DR_ROOT/core/event-bus/event-bus.sh"

# ─── deploy_release_init ─────────────────────────────────────────────────────
deploy_release_init() {
    export ZBUILD_PLUGIN="deploy-release"
    export ZBUILD_PLUGIN_KIND="tool"
    emit_event "plugin.init.start" "plugin=deploy-release"
    return 0
}

# ─── deploy_release_run ──────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
deploy_release_run() {
    local stage_id="${1:-deploy}"; : "$stage_id"
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "deploy_release_run: state_file argument required"
        return 2
    fi

    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    local pr_url_in="$artifacts_dir/pr-url.txt"
    local deploy_result_out="$artifacts_dir/deploy-result.json"
    mkdir -p "$artifacts_dir"

    local pr_url=""
    [[ -f "$pr_url_in" ]] && pr_url="$(tr -d '[:space:]' < "$pr_url_in")"

    # Dry-run: write sentinel without executing git/gh
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        jq -n --arg pr_url "$pr_url" \
            '{schema_version:1,verdict:"deployed",mode:"dry_run",pr_url:$pr_url}' \
            | atomic_write "$deploy_result_out"
        emit_event "deploy.release.dry_run" "plugin=deploy-release"
        return 0
    fi

    # Real deploy: create a tag at HEAD and push it. Sanitize the run id to a safe
    # git ref (strip anything outside [A-Za-z0-9_-]) so ZBUILD_RUN_ID cannot inject
    # git ref syntax such as '@{...}' or ':' (#757 review finding).
    local _run_id="${ZBUILD_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
    _run_id="${_run_id//[^A-Za-z0-9_-]/_}"
    local tag_name="zbuild-run-${_run_id}"

    if ! git tag "$tag_name" 2>/dev/null; then
        error "deploy-release: git tag failed for $tag_name"
        jq -n --arg tag "$tag_name" \
            '{schema_version:1,verdict:"error",reason:"git tag failed",tag:$tag}' \
            > "$deploy_result_out"
        return 1
    fi

    if ! git push origin "$tag_name" 2>/dev/null; then
        error "deploy-release: git push tag failed for $tag_name"
        # Roll back the local tag so a retry is not blocked by a stale tag (#757 review).
        git tag -d "$tag_name" 2>/dev/null || true
        jq -n --arg tag "$tag_name" \
            '{schema_version:1,verdict:"error",reason:"git push tag failed",tag:$tag}' \
            > "$deploy_result_out"
        return 1
    fi

    jq -n --arg tag "$tag_name" --arg pr_url "$pr_url" \
        '{schema_version:1,verdict:"deployed",tag:$tag,pr_url:$pr_url}' \
        | atomic_write "$deploy_result_out"
    emit_event "deploy.release.complete" "plugin=deploy-release" "tag=$tag_name"
    return 0
}

# ─── deploy_release_finalize ─────────────────────────────────────────────────
deploy_release_finalize() {
    emit_event "plugin.finalize.complete" "plugin=deploy-release"
    return 0
}

# ─── deploy_release_cleanup ──────────────────────────────────────────────────
deploy_release_cleanup() {
    return 0
}
