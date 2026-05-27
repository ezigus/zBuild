#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/build — Build stage agent (issue #341)                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: build (ADR-013, T2, blocking)
# Produces: state/artifacts/diff.patch AND state/artifacts/build-summary.json
#
# CRITICAL: The diff.patch is NEVER applied inside this plugin. It is written
# as an artifact only — the downstream test stage is responsible for applying
# and validating it against the working tree.
#
# Lifecycle:
#   build_stage_init        — set env vars, emit plugin.init.start
#   build_stage_run         — derive paths, delegate to _build_stage_run_inner
#   _build_stage_run_inner  — redact → route → extract diff → write artifacts
#   build_stage_finalize    — emit plugin.finalize.complete
#   build_stage_cleanup     — emit plugin.cleanup.done, return 0

[[ -n "${_ZBUILD_BUILD_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_LOADED=1

_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BUILD_ROOT="$(cd "$_BUILD_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$_BUILD_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_BUILD_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_BUILD_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_BUILD_ROOT/core/router/route.sh"

# ─── init ───────────────────────────────────────────────────────────────────
build_stage_init() {
    export ZBUILD_PLUGIN="build"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=build"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: build_stage_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
build_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "build_stage_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local scope_manifest="$state_dir/scope-manifest.md"
    if [[ ! -f "$scope_manifest" ]]; then
        error "build_stage_run: scope-manifest.md not found at $scope_manifest"
        return 2
    fi

    local plan_json_path="$artifacts_dir/plan.json"

    _build_stage_run_inner \
        "$scope_manifest" \
        "$plan_json_path" \
        "$artifacts_dir/diff.patch" \
        "$artifacts_dir/build-summary.json" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan_json_path
#   $3 = output_diff_patch path
#   $4 = output_summary_json path
#   $5 = artifact_dir for intermediate files
_build_stage_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local output_diff_patch="$3"
    local output_summary_json="$4"
    local artifact_dir="${5:-$(dirname "$output_summary_json")}"

    if [[ -z "$scope_manifest" || -z "$plan_json_path" || -z "$output_diff_patch" || -z "$output_summary_json" ]]; then
        error "_build_stage_run_inner: requires <scope_manifest> <plan_json_path> <output_diff_patch> <output_summary_json> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    # ─── Read plan.json — fail rc=2 if missing ───────────────────────────────
    if [[ ! -f "$plan_json_path" ]]; then
        error "_build_stage_run_inner: plan.json not found at $plan_json_path"
        emit_event "plugin.run.error" "plugin=build" "reason=missing_plan_json"
        return 2
    fi

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # ─── Write prompt to a file for the redaction chokepoint ────────────────
    local prompt_input_file="$artifact_dir/build-prompt.txt"
    printf 'Implement the plan: %s\n' "$plan_json" > "$prompt_input_file"

    local redacted_file="$artifact_dir/build-prompt.redacted.txt"

    # ─── Redaction chokepoint (REQUIRED — ADR-004) ───────────────────────────
    if ! apply_scope_redaction "$prompt_input_file" "$redacted_file" "$scope_manifest" "" "0"; then
        error "_build_stage_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=build" "reason=redaction_failed"
        return 1
    fi

    local redacted_input
    redacted_input="$(cat "$redacted_file")"

    # ─── Route to LLM (T2, matching manifest config.tier_default) ───────────
    local tier="${ZBUILD_BUILD_TIER:-T2}"
    local raw_response="" router_rc=0
    raw_response="$(route_to_model "$tier" "$redacted_input" 2>/dev/null)" || router_rc=$?

    if [[ $router_rc -ne 0 && $router_rc -ne 1 ]]; then
        error "_build_stage_run_inner: router rc=$router_rc (fatal)"
        emit_event "plugin.run.error" "plugin=build" \
            "reason=router_fatal" "router_rc=$router_rc"
        return 1
    fi

    if [[ $router_rc -eq 1 ]]; then
        warn "_build_stage_run_inner: router rc=1 (recoverable); using empty diff"
        raw_response=""
    fi

    # ─── Extract diff.patch from LLM response ────────────────────────────────
    # The LLM response is expected to contain a unified diff. We extract the
    # diff block — either a fenced ```diff block or the raw diff starting with
    # "diff --git". If neither is present, write an empty patch file.
    local diff_content=""
    if [[ -n "$raw_response" ]]; then
        # Try to extract a fenced diff block first
        local stripped
        stripped="$(printf '%s' "$raw_response" \
            | sed 's/^[[:space:]]*```diff[[:space:]]*//' \
            | sed 's/^[[:space:]]*```patch[[:space:]]*//' \
            | sed 's/^[[:space:]]*```[[:space:]]*//' \
            | sed 's/[[:space:]]*```[[:space:]]*$//')"

        # Check if the response (or stripped version) looks like a diff
        if printf '%s' "$stripped" | grep -q '^diff --git'; then
            diff_content="$stripped"
        elif printf '%s' "$raw_response" | grep -q '^diff --git'; then
            diff_content="$raw_response"
        else
            warn "_build_stage_run_inner: LLM response does not contain a recognizable diff; using empty patch"
        fi
    fi

    # ─── Write diff.patch ────────────────────────────────────────────────────
    # NEVER apply the diff here — write only. Test stage applies it.
    printf '%s\n' "$diff_content" > "$output_diff_patch"

    # ─── Parse diff stats (files changed, lines added/removed) ───────────────
    local files_changed_json="[]"
    local lines_added=0
    local lines_removed=0

    if [[ -n "$diff_content" ]]; then
        # Extract changed file paths from "diff --git a/foo b/foo" lines
        local changed_files_raw
        changed_files_raw="$(printf '%s' "$diff_content" \
            | grep '^diff --git' \
            | sed 's|^diff --git a/[^ ]* b/||' || true)"
        if [[ -n "$changed_files_raw" ]]; then
            files_changed_json="$(printf '%s\n' "$changed_files_raw" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
        fi
        lines_added="$(printf '%s' "$diff_content" \
            | grep -c '^+' 2>/dev/null || true)"
        lines_removed="$(printf '%s' "$diff_content" \
            | grep -c '^-' 2>/dev/null || true)"
        # Subtract the +++ / --- header lines
        local header_plus header_minus
        header_plus="$(printf '%s' "$diff_content" | grep -c '^+++' 2>/dev/null || true)"
        header_minus="$(printf '%s' "$diff_content" | grep -c '^---' 2>/dev/null || true)"
        lines_added=$(( lines_added - header_plus ))
        lines_removed=$(( lines_removed - header_minus ))
        [[ $lines_added -lt 0 ]] && lines_added=0
        [[ $lines_removed -lt 0 ]] && lines_removed=0
    fi

    local files_changed_count
    files_changed_count="$(printf '%s' "$files_changed_json" | jq 'length' 2>/dev/null || echo 0)"

    # ─── Write build-summary.json ────────────────────────────────────────────
    local issue="${ZBUILD_ISSUE:-0}"
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
        issue=0
    fi

    jq -n \
        --argjson schema_version 1 \
        --argjson issue "$issue" \
        --argjson files_changed "$files_changed_json" \
        --argjson lines_added "$lines_added" \
        --argjson lines_removed "$lines_removed" \
        --arg diff_patch_path "$output_diff_patch" \
        --arg notes "Build stage completed. Diff written to artifact; not applied." \
        '{
            schema_version: $schema_version,
            issue: $issue,
            files_changed: $files_changed,
            lines_added: $lines_added,
            lines_removed: $lines_removed,
            diff_patch_path: $diff_patch_path,
            notes: $notes
        }' | atomic_write "$output_summary_json"

    # ─── Validate diff.patch with git apply --check (warn-only) ─────────────
    # Failure here is a warning, not a fatal error — the test stage is the
    # authoritative validator.
    if [[ -n "$diff_content" ]] && command -v git >/dev/null 2>&1; then
        if ! git apply --check "$output_diff_patch" >/dev/null 2>&1; then
            warn "_build_stage_run_inner: git apply --check failed on diff.patch; test stage will catch this"
            emit_event "build.diff.validation_warning" "plugin=build" \
                "reason=git_apply_check_failed" \
                "diff_patch=$output_diff_patch"
        fi
    fi

    emit_event "stage.complete" "stage=build" \
        "plugin=build" \
        "files_changed_count=$files_changed_count" \
        "lines_added=$lines_added" \
        "lines_removed=$lines_removed" \
        "artifact=build-summary.json"
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
build_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=build"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
build_stage_cleanup() {
    emit_event "plugin.cleanup.done" "plugin=build"
    return 0
}
