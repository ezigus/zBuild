#!/usr/bin/env bash
# plugins/tool/deploy-release — deploy-release executor (kind:tool, T0, issue #757)
# Creates + pushes a git tag at HEAD (tag-based release). No `gh` call, no LLM.
# Invoked by the deploy agent. ZBUILD_DRY_RUN=1 writes a sentinel
# deploy-result.json without executing git.

[[ -n "${_ZBUILD_DEPLOY_RELEASE_LOADED:-}" ]] && return 0
_ZBUILD_DEPLOY_RELEASE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_DR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DR_ROOT/core/event-bus/event-bus.sh"

# ─── deploy_release_run ──────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
deploy_release_run() {
    local stage_id="${1:-deploy}"; : "$stage_id"
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "deploy_release_run: state_file argument required"
        if [[ -n "${ZBUILD_ARTIFACT_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_ARTIFACT_DIR"
            jq -n '{"result_contract":2,"verdict":"error","disposition":"broken","reason":"state_file argument required"}' \
                > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
        fi
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/deploy-release-summary.md}" "deploy-release" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 1
    fi

    # The engine names where results go (ZBUILD_ARTIFACT_DIR); a path derived
    # from the state file drifted from it whenever the two differed, and the
    # deploy agent then read a result this plugin never wrote there (review #2219).
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"
    if [[ -z "$artifacts_dir" ]]; then
        error "deploy_release_run: ZBUILD_ARTIFACT_DIR not set — nowhere to write a result"
        emit_event "deploy.release.unwritable" "plugin=deploy-release" "disposition=broken"
        return 1
    fi
    local deploy_result_out="$artifacts_dir/deploy-result.json"
    mkdir -p "$artifacts_dir"

    # ADR-055 §1: the declared input reaches this plugin through the engine's
    # index and nowhere else (lifecycle.sh exports it for the calling stage).
    local _pr_url_path=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -f "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        _pr_url_path="$(jq -r '.inputs.pr_url // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    local pr_url=""
    [[ -n "$_pr_url_path" && -f "$_pr_url_path" ]] && pr_url="$(tr -d '[:space:]' < "$_pr_url_path")"

    # Dry-run: write sentinel without executing git/gh
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        atomic_write "$deploy_result_out" <<< "$(jq -n --arg pr_url "$pr_url" \
            '{"result_contract":2,"verdict":"deployed","disposition":"complete","reason":"dry run — release simulated, no tag created","data":{"mode":"dry_run","pr_url":$pr_url}}')"
        emit_event "deploy.release.dry_run" "plugin=deploy-release"
        stage_summary_write "$artifacts_dir/deploy-release-summary.md" "deploy-release" "skip" \
            "dry run — no tag was created and nothing was pushed" \
            "No release was cut. This verdict asserts nothing about a real deploy."
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
        atomic_write "$deploy_result_out" <<< "$(jq -n --arg tag "$tag_name" \
            '{"result_contract":2,"verdict":"error","disposition":"broken","reason":"git tag failed","data":{"tag":$tag}}')"
        stage_summary_write "$artifacts_dir/deploy-release-summary.md" "deploy-release" "fail" \
            "could not create the release tag $tag_name" \
            "No release was cut. The tag may already exist from an earlier run."
        return 1
    fi

    if ! git push origin "$tag_name" 2>/dev/null; then
        error "deploy-release: git push tag failed for $tag_name"
        # Roll back the local tag so a retry is not blocked by a stale tag (#757 review).
        git tag -d "$tag_name" 2>/dev/null || true
        atomic_write "$deploy_result_out" <<< "$(jq -n --arg tag "$tag_name" \
            '{"result_contract":2,"verdict":"error","disposition":"unavailable","reason":"git push tag failed","data":{"tag":$tag}}')"
        stage_summary_write "$artifacts_dir/deploy-release-summary.md" "deploy-release" "fail" \
            "could not push the release tag $tag_name to origin" \
            "No release was cut. The local tag was rolled back so a retry is not blocked."
        return 1
    fi

    atomic_write "$deploy_result_out" <<< "$(jq -n --arg tag "$tag_name" --arg pr_url "$pr_url" \
        '{"result_contract":2,"verdict":"deployed","disposition":"complete","reason":"git tag created and pushed to origin","data":{"tag":$tag,"pr_url":$pr_url}}')"
    emit_event "deploy.release.complete" "plugin=deploy-release" "tag=$tag_name"
    stage_summary_write "$artifacts_dir/deploy-release-summary.md" "deploy-release" "pass" \
        "cut release tag $tag_name and pushed it to origin" \
        "$(printf -- '- tag: %s\n- pr: %s' "$tag_name" "${pr_url:-<none>}")"
    return 0
}

# ─── deploy_release_cleanup ──────────────────────────────────────────────────
