#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/design — Design stage agent (issue #754)                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: design (ADR-013 T2, ADR-018 Pattern 1 — agent-loop writes design.md)
# Produces: state/artifacts/design.md
#
# Lifecycle:
#   design_stage_init     — set env vars, emit plugin.init.start
#   design_stage_run      — derive paths, delegate to _design_stage_run_inner
#   _design_stage_run_inner — redact → route_to_model_loop → verify design.md
#   design_stage_finalize — emit plugin.finalize.complete
#   design_stage_cleanup  — emit plugin.cleanup.complete
#
# Legacy citations (pipeline-stages-intake.sh:1004 = stage_design,
# pipeline-stages.sh:38-71 = _extract_scope_from_design).

[[ -n "${_ZBUILD_DESIGN_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_DESIGN_DIR="$_ZBUILD_PLUGIN_DIR"
_DESIGN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_DESIGN_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DESIGN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_DESIGN_ROOT/core/router/route.sh"
# shellcheck source=../../../core/output/stage-io.sh
source "$_DESIGN_ROOT/core/output/stage-io.sh"

# ─── init ───────────────────────────────────────────────────────────────────
design_stage_init() {
    export ZBUILD_PLUGIN="design"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=design"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
design_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "design_stage_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    _design_stage_run_inner \
        "$state_dir/scope-manifest.md" \
        "$artifacts_dir/plan.json" \
        "$artifacts_dir/design.md" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan_json path
#   $3 = output_design_md path
#   $4 = artifact_dir
_design_stage_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local output_design_md="$3"
    local artifact_dir="${4:-$(dirname "$output_design_md")}"

    if [[ -z "$scope_manifest" || -z "$plan_json_path" || -z "$output_design_md" ]]; then
        error "_design_stage_run_inner: requires <scope_manifest> <plan_json_path> <output_design_md> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    if [[ ! -f "$plan_json_path" ]]; then
        error "_design_stage_run_inner: plan.json not found at $plan_json_path"
        emit_event "plugin.run.error" "plugin=design" "reason=missing_plan_json"
        return 2
    fi

    emit_event "plugin.run.start" "plugin=design"

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # Extract plan.files[] — minimum scope that design.md must cover.
    local plan_files_csv=""
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    # ─── Write design prompt ─────────────────────────────────────────────────
    local prompt_file="$artifact_dir/design-prompt.txt"
    local _scope_list=""
    if [[ -n "$plan_files_csv" ]]; then
        _scope_list="$(printf '%s\n' "$plan_files_csv" | tr ',' '\n' | sed 's/^/  - /')"
    fi

    cat > "$prompt_file" <<DESIGN_PROMPT
You are the design stage agent for zBuild. Analyze the plan below and produce
a design document at: ${output_design_md}

## Plan
$(printf '%s' "$plan_json")

## Minimum scope (from plan.json — your scope block MUST include all of these)
${_scope_list}

## Instructions
1. Write a concise design document to: ${output_design_md}
2. The document MUST contain a \`\`\`scope fenced block listing one file path
   per line. The scope block lists every file the build stage will touch.
3. The scope block MUST be a strict superset of the minimum scope above —
   include ALL files listed above, plus any additional files needed.
4. Use the Write tool to write the file, then emit LOOP_COMPLETE.

### Completion sentinel
Emit \`LOOP_COMPLETE\` as the FINAL line of your response when done.

COMMIT_SUMMARY: add design.md with scope block for build stage
DESIGN_PROMPT

    # ─── Redaction chokepoint (REQUIRED — ADR-004) ──────────────────────────
    local redacted_file="$artifact_dir/design-prompt.redacted.txt"
    if ! apply_scope_redaction "$prompt_file" "$redacted_file" "$scope_manifest" "" "0"; then
        error "_design_stage_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=design" "reason=redaction_failed"
        return 1
    fi

    # ─── Route through agent loop (ADR-018 Pattern 1) ────────────────────────
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier="${ZBUILD_DESIGN_TIER:-T2}"
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 5)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=5
    [[ "$max_iter" -gt 5 ]] && max_iter=5

    export ZBUILD_SCOPE_MANIFEST="$scope_manifest"

    local router_rc=0
    route_to_model_loop "$tier" "$redacted_file" "$repo_root" "$max_iter" \
        --scope-allowlist "" || router_rc=$?

    local iterations="${_ROUTE_LOOP_ITERATIONS:-0}"
    local terminated_reason="${_ROUTE_LOOP_TERMINATED_REASON:-error}"

    if [[ $router_rc -eq 130 ]]; then
        warn "_design_stage_run_inner: route_to_model_loop rc=130 (SIGINT) — propagating"
        emit_event "design.aborted" "plugin=design" "reason=sigint" >/dev/null 2>&1 || true
        return 130
    fi

    if [[ $router_rc -ge 2 ]]; then
        warn "_design_stage_run_inner: route_to_model_loop rc=$router_rc"
    fi

    # ─── Verify design.md was written with a scope block ─────────────────────
    if [[ ! -s "$output_design_md" ]]; then
        error "_design_stage_run_inner: design.md not written by agent loop"
        emit_event "plugin.run.error" "plugin=design" "reason=missing_design_md"
        return 1
    fi

    # Persist design.md atomically (ADR-007) — the LLM wrote it; re-stage
    # through atomic_write so a crash mid-write leaves no partial artifact.
    cat "$output_design_md" | atomic_write "$output_design_md"

    # Count files in the ```scope block for the scope_injected event.
    local scope_file_count=0
    local in_block=0
    while IFS= read -r line; do
        if [[ "$in_block" -eq 0 && "$line" == '```scope' ]]; then
            in_block=1
            continue
        fi
        if [[ "$in_block" -eq 1 ]]; then
            [[ "$line" == '```' ]] && break
            local _trimmed
            _trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
            [[ -n "$_trimmed" ]] && scope_file_count=$(( scope_file_count + 1 ))
        fi
    done < "$output_design_md"

    emit_event "build.scope_injected" "plugin=design" \
        "file_count=$scope_file_count" "source=design.md"

    emit_event "plugin.run.complete" "plugin=design" \
        "stage=design" \
        "iterations=$iterations" \
        "terminated_reason=$terminated_reason" \
        "scope_file_count=$scope_file_count" \
        "artifact=design.md"

    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
design_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=design"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
design_stage_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=design"
    return 0
}
