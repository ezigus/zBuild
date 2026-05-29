#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/build — Build stage agent (issues #341, #467)              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: build (ADR-013 T2, ADR-018 Pattern 2 — agent-loop with derived diff)
# Produces: state/artifacts/diff.patch AND state/artifacts/build-summary.json
#
# Lifecycle:
#   build_stage_init        — set env vars, emit plugin.init.start
#   build_stage_run         — derive paths, delegate to _build_stage_run_inner
#   _build_stage_run_inner  — redact → route_to_model_loop → git diff → write
#   build_stage_finalize    — emit plugin.finalize.complete
#   build_stage_cleanup     — emit plugin.cleanup.complete
#
# CRITICAL: diff.patch is NEVER applied here — it is the working-tree diff
# left by the agent loop, captured via `git diff HEAD` after the loop returns.
# The downstream test stage applies and validates it.

[[ -n "${_ZBUILD_BUILD_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_BUILD_DIR="$_ZBUILD_PLUGIN_DIR"
_BUILD_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_BUILD_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_BUILD_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_BUILD_ROOT/core/router/route.sh"
# ADR-018 (#470): artifact renderer registry for inter-stage markdown.
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_BUILD_ROOT/scripts/lib/artifact-render.sh"
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_BUILD_ROOT/scripts/lib/artifact-render.sh"

# ─── init ───────────────────────────────────────────────────────────────────
build_stage_init() {
    export ZBUILD_PLUGIN="build"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=build"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
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

    if [[ ! -f "$plan_json_path" ]]; then
        error "_build_stage_run_inner: plan.json not found at $plan_json_path"
        emit_event "plugin.run.error" "plugin=build" "reason=missing_plan_json"
        return 2
    fi

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # Extract plan.files[] — the canonical scope for this build. Falls back to
    # plan.steps[].files[] for the legacy plan shape used by some fixtures.
    local plan_files_csv=""
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    # ─── Write build prompt (ADR-018 Pattern 2) ──────────────────────────────
    local prompt_input_file="$artifact_dir/build-prompt.txt"
    local _build_instructions
    _build_instructions="$(_build_compose_instructions "$plan_files_csv")"

    # ADR-018 (#470): render plan.json as markdown for LLM consumption when
    # the renderer registry is available. Falls back to raw JSON otherwise.
    local plan_payload="$plan_json"
    if declare -F render_artifact >/dev/null 2>&1; then
        plan_payload="$(render_artifact plan "$plan_json" 2>/dev/null || echo "$plan_json")"
    fi
    local prompt
    printf -v prompt '%s\n\n## Plan\n%s\n' "$_build_instructions" "$plan_payload"
    printf '%s\n' "$prompt" > "$prompt_input_file"

    local redacted_file="$artifact_dir/build-prompt.redacted.txt"

    if ! apply_scope_redaction "$prompt_input_file" "$redacted_file" "$scope_manifest" "" "0"; then
        error "_build_stage_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=build" "reason=redaction_failed"
        return 1
    fi

    # ─── Route through agent loop (ADR-018 Pattern 2) ────────────────────────
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier="${ZBUILD_BUILD_TIER:-T2}"
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 10)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=10

    # Expose the scope manifest path so per-iteration redaction inside the loop
    # can satisfy C6 without inlining the manifest at every consumer.
    export ZBUILD_SCOPE_MANIFEST="$scope_manifest"

    local router_rc=0
    route_to_model_loop "$tier" "$redacted_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" 2>/dev/null || router_rc=$?

    local iterations="${_ROUTE_LOOP_ITERATIONS:-0}"
    local terminated_reason="${_ROUTE_LOOP_TERMINATED_REASON:-error}"
    local loop_input_tokens="${_ROUTE_LOOP_INPUT_TOKENS:-0}"
    local loop_output_tokens="${_ROUTE_LOOP_OUTPUT_TOKENS:-0}"

    if [[ $router_rc -ge 2 ]]; then
        warn "_build_stage_run_inner: route_to_model_loop rc=$router_rc — writing empty diff and summary"
        terminated_reason="error"
    fi

    # ─── Derive diff.patch from git working tree ─────────────────────────────
    # `git add -N` (intent-to-add) makes untracked files appear in `git diff HEAD`
    # without staging their content. Without it, new files created by the agent
    # would be silently dropped from the canonical diff.
    git -C "$repo_root" add -N . 2>/dev/null || true
    local diff_content="" diff_rc=0
    diff_content="$(git -C "$repo_root" diff HEAD 2>/dev/null)" || diff_rc=$?
    if [[ $diff_rc -ne 0 ]]; then
        warn "_build_stage_run_inner: git diff HEAD failed in $repo_root"
        emit_event "loop.git_diff_failed" "plugin=build" "cwd=$repo_root" "rc=$diff_rc"
        diff_content=""
    fi

    # ─── Scope post-validation via git diff --name-status -z ─────────────────
    local scope_violation="false"
    local -a scope_violations=()
    if [[ -n "$diff_content" && -n "$plan_files_csv" ]]; then
        local -a allowed_files=()
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206,SC2034
        # SC2206: word-split intentional. SC2034: passed to _build_path_in_scope
        # via nameref (local -n _allowed_ref), which shellcheck cannot follow.
        allowed_files=( $plan_files_csv )
        IFS="$IFS_save"

        # name-status -z output: <STATUS>\0<path1>[\0<path2>] for renames.
        # NULs are stripped by command substitution; route through a temp file
        # so the NUL-delimited tokens survive intact.
        local _ns_file="$artifact_dir/.build-name-status.bin"
        git -C "$repo_root" diff --name-status -z HEAD > "$_ns_file" 2>/dev/null || :

        local -a tokens=()
        while IFS= read -r -d '' tok; do
            tokens+=("$tok")
        done < "$_ns_file"
        rm -f "$_ns_file"

        local i n=${#tokens[@]}
        i=0
        while (( i < n )); do
            local status="${tokens[$i]}"
            i=$((i+1))
            local first_path="${tokens[$i]:-}"
            i=$((i+1))
            local -a paths_to_check=("$first_path")
            # Renames/copies (R*/C*) emit two paths: old + new.
            if [[ "$status" =~ ^[RC] ]]; then
                paths_to_check+=("${tokens[$i]:-}")
                i=$((i+1))
            fi
            local p
            for p in "${paths_to_check[@]}"; do
                [[ -z "$p" ]] && continue
                if ! _build_path_in_scope "$p" allowed_files; then
                    scope_violation="true"
                    scope_violations+=("$p")
                    emit_event "build.scope.violation" "plugin=build" \
                        "path=$p" "status=$status"
                fi
            done
        done
    fi

    if [[ "$scope_violation" == "true" ]]; then
        warn "_build_stage_run_inner: scope violation — writing empty diff.patch"
        diff_content=""
    fi

    # Empty-diff signal: emit warn event when prose-only / no edits produced.
    if [[ -z "$diff_content" && "$scope_violation" != "true" && $router_rc -lt 2 ]]; then
        emit_event "build.empty_diff" "plugin=build" \
            "iterations=$iterations" "terminated_reason=$terminated_reason"
    fi

    # ─── Write diff.patch (NEVER applied here) ───────────────────────────────
    printf '%s' "$diff_content" > "$output_diff_patch"

    # ─── Parse diff stats ────────────────────────────────────────────────────
    local files_changed_json="[]" lines_added=0 lines_removed=0
    if [[ -n "$diff_content" ]]; then
        local changed_files_raw
        changed_files_raw="$(printf '%s' "$diff_content" \
            | grep '^diff --git' \
            | sed 's|^diff --git a/[^ ]* b/||' || true)"
        if [[ -n "$changed_files_raw" ]]; then
            files_changed_json="$(printf '%s\n' "$changed_files_raw" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
        fi
        lines_added="$(printf '%s' "$diff_content" | grep -c '^+' 2>/dev/null || true)"
        lines_removed="$(printf '%s' "$diff_content" | grep -c '^-' 2>/dev/null || true)"
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

    # ─── Write build-summary.json (schema_version=2) ─────────────────────────
    local issue="${ZBUILD_ISSUE:-0}"
    [[ "$issue" =~ ^[0-9]+$ ]] || issue=0

    local violations_json="[]"
    if [[ ${#scope_violations[@]} -gt 0 ]]; then
        violations_json="$(printf '%s\n' "${scope_violations[@]}" \
            | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
    fi

    jq -n \
        --argjson schema_version 2 \
        --argjson issue "$issue" \
        --argjson files_changed "$files_changed_json" \
        --argjson lines_added "$lines_added" \
        --argjson lines_removed "$lines_removed" \
        --arg diff_patch_path "$output_diff_patch" \
        --argjson iterations "$iterations" \
        --arg terminated_reason "$terminated_reason" \
        --argjson scope_violation "$([[ "$scope_violation" == "true" ]] && echo true || echo false)" \
        --argjson scope_violations "$violations_json" \
        --argjson loop_input_tokens "$loop_input_tokens" \
        --argjson loop_output_tokens "$loop_output_tokens" \
        --arg notes "Build stage completed. Diff written to artifact; not applied." \
        '{
            schema_version: $schema_version,
            issue: $issue,
            files_changed: $files_changed,
            lines_added: $lines_added,
            lines_removed: $lines_removed,
            diff_patch_path: $diff_patch_path,
            iterations: $iterations,
            terminated_reason: $terminated_reason,
            scope_violation: $scope_violation,
            scope_violations: $scope_violations,
            loop_input_tokens: $loop_input_tokens,
            loop_output_tokens: $loop_output_tokens,
            notes: $notes
        }' | atomic_write "$output_summary_json"

    emit_event "plugin.run.complete" "stage=build" \
        "plugin=build" \
        "files_changed_count=$files_changed_count" \
        "lines_added=$lines_added" \
        "lines_removed=$lines_removed" \
        "iterations=$iterations" \
        "terminated_reason=$terminated_reason" \
        "scope_violation=$scope_violation" \
        "artifact=build-summary.json"
    return 0
}

# _build_compose_instructions <plan_files_csv>
# Emits the static portion of the build prompt. Per ADR-018 Pattern 2:
# Read/Edit/Write/Bash tools are available; the loop watches `git diff HEAD`;
# completion is signaled by emitting `LOOP_COMPLETE` on its own line.
_build_compose_instructions() {
    local plan_files_csv="${1:-}"
    local scope_section=""
    if [[ -n "$plan_files_csv" ]]; then
        scope_section="$(printf '%s\n' "$plan_files_csv" | tr ',' '\n' | sed 's/^/  - /')"
    else
        scope_section="  (no plan.files[] declared — refuse to edit if scope is unclear)"
    fi
    cat <<BUILD_PROMPT
You are an autonomous build agent for zBuild. You have Read, Edit, Write, and
Bash tools available. Your job is to edit the working tree to implement the
plan below.

## Scope (plan.files[])
You may ONLY touch files listed here. Refuse any out-of-scope edit.
${scope_section}

## How the loop works
- Each iteration you may make code changes via Edit/Write/Bash.
- After each iteration the pipeline captures \`git diff HEAD\` and feeds it
  back to you so you can verify progress.
- Do NOT emit a unified diff in your response — the pipeline derives the
  canonical \`diff.patch\` artifact from \`git diff HEAD\` automatically.

## Completion sentinel
When the implementation is complete and tests would pass, emit \`LOOP_COMPLETE\`
on its own line as the FINAL line of your response. This terminates the loop.

## Rules
- Touch only files in the scope list above.
- Do not run \`git commit\` — the pipeline owns commit semantics.
- Keep changes minimal and aligned with the plan.
BUILD_PROMPT
}

# _build_path_in_scope <path> <allowed_files_array_name>
# Prefix match: an allowed path covers itself and any descendants. Returns 0
# (in scope) or 1 (violation).
_build_path_in_scope() {
    local path="$1"
    local -n _allowed_ref="$2"
    local allowed
    for allowed in "${_allowed_ref[@]}"; do
        [[ -z "$allowed" ]] && continue
        # Exact match
        [[ "$path" == "$allowed" ]] && return 0
        # Directory prefix (allowed=core/ → path=core/foo.sh in scope)
        if [[ "$allowed" == */ ]]; then
            [[ "$path" == "${allowed}"* ]] && return 0
        else
            # Allowed is a file or implicit dir; treat as prefix when followed by /
            [[ "$path" == "${allowed}/"* ]] && return 0
        fi
    done
    return 1
}

# ─── finalize ───────────────────────────────────────────────────────────────
build_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=build"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
build_stage_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=build"
    return 0
}
