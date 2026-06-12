#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/design — Design stage agent (issue #754)                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: design (ADR-013 T2, ADR-018 Pattern 2 — agent-loop, single-file artifact)
# (Reclassified from Pattern 1 in ADR-018 Amendment v4, #816.)
# Produces: state/artifacts/design.md with embedded ```scope fenced block
#
# Lifecycle:
#   design_stage_init        — set env vars, emit plugin.init.start
#   design_stage_run         — derive paths, delegate to _design_stage_run_inner
#   _design_stage_run_inner  — redact → route_to_model_loop → assert scope block
#   design_stage_finalize    — emit plugin.finalize.complete
#   design_stage_cleanup     — emit plugin.cleanup.complete
#
# legacy-citation: pipeline-stages-intake.sh:1004 (stage_design function)
# legacy-citation: pipeline-stages.sh:38-71 (_extract_scope_from_design helper)

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

    local scope_manifest="$state_dir/scope-manifest.md"
    local plan_json_path="$artifacts_dir/plan.json"

    _design_stage_run_inner \
        "$scope_manifest" \
        "$plan_json_path" \
        "$artifacts_dir/design.md" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan_json_path
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

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # Extract plan.files[] as the seed scope for design.md's scope block.
    local plan_files_csv=""
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    local scope_list=""
    if [[ -n "$plan_files_csv" ]]; then
        scope_list="$(printf '%s' "$plan_files_csv" | tr ',' '\n' | sed 's/^/- /')"
    fi

    local prompt_input_file="$artifact_dir/design-prompt.txt"

    cat > "$prompt_input_file" <<DESIGN_PROMPT
You are a software architect for zBuild. Your job is to produce an ADR-style
design.md for the task described in the plan below.

## Plan
$(printf '%s' "$plan_json" | jq -r '.title // "Untitled"' 2>/dev/null)

$(printf '%s' "$plan_json" | jq -r '.description // .goal // ""' 2>/dev/null)

## Seed scope (from plan.files[])
${scope_list}

## Instructions

Write the design document to this EXACT absolute path:
  $output_design_md
Do NOT write to ./design.md, design.md, or any other path. The harvester
expects the file at the absolute path above; any other location is a
contract violation that will fail this stage.

The design document MUST include:
1. A brief architectural decision summary (goal, context, decision).
2. A \`\`\`scope fenced block listing all files that will be touched by this
   task. The scope block MUST be a superset of the seed scope above — every
   file in the seed scope must appear in your \`\`\`scope block.

The \`\`\`scope block format:
\`\`\`scope
path/to/file1
path/to/file2
\`\`\`

Keep the document focused and under 200 lines. Emit LOOP_COMPLETE when done.
DESIGN_PROMPT

    local redacted_file="$artifact_dir/design-prompt.redacted.txt"

    if ! apply_scope_redaction "$prompt_input_file" "$redacted_file" "$scope_manifest" "$plan_files_csv" "0"; then
        error "_design_stage_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=design" "reason=redaction_failed"
        return 1
    fi

    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier="${ZBUILD_DESIGN_TIER:-T2}"
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 5)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=5

    export ZBUILD_SCOPE_MANIFEST="$scope_manifest"

    local router_rc=0
    route_to_model_loop "$tier" "$redacted_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" || router_rc=$?

    if [[ $router_rc -eq 130 ]]; then
        warn "_design_stage_run_inner: route_to_model_loop rc=130 (SIGINT) — propagating abort"
        return 130
    fi

    if [[ $router_rc -ge 2 ]]; then
        warn "_design_stage_run_inner: route_to_model_loop rc=$router_rc — design stage failed"
        emit_event "plugin.run.error" "plugin=design" "reason=router_error" "rc=$router_rc"
        return 1
    fi

    # ADR-018 Pattern 2 single-file-artifact contract (#817): recover stray
    # design.md written by the LLM to repo root despite the explicit
    # destination path in the prompt. Two cases:
    #   - sibling at $repo_root/design.md is NOT git-tracked → mv into place
    #     and emit `design.stray.recovered` for forensics
    #   - sibling IS git-tracked → refuse (legitimate operator-checked-in
    #     doc; never touch). Emit `design.stray.conflict reason=tracked` and
    #     fail so the operator notices the mis-write.
    if [[ ! -f "$output_design_md" ]]; then
        local _stray="$repo_root/design.md"
        if [[ -f "$_stray" ]]; then
            if git -C "$repo_root" ls-files --error-unmatch "design.md" >/dev/null 2>&1; then
                error "_design_stage_run_inner: tracked design.md at repo root; refusing to relocate (operator-owned)"
                emit_event "design.stray.conflict" "plugin=design" "path=$_stray" "reason=tracked"
                return 1
            fi
            mkdir -p "$artifact_dir"
            if mv "$_stray" "$output_design_md" 2>/dev/null; then
                warn "_design_stage_run_inner: recovered design.md from repo root → $output_design_md"
                emit_event "design.stray.recovered" "plugin=design" "from=$_stray" "to=$output_design_md"
            fi
        fi
    fi

    # Assert the scope block is present in design.md.
    if [[ ! -f "$output_design_md" ]]; then
        error "_design_stage_run_inner: design.md not produced at $output_design_md"
        emit_event "plugin.run.error" "plugin=design" "reason=missing_design_md"
        return 1
    fi

    # #817: single-quoted backticks need no escaping. Prior pattern
    # '^\`\`\`scope' worked on macOS BSD grep (silently drops unknown \X
    # escapes) but failed on Linux GNU grep (treats \` as backslash+backtick).
    # Use plain literal triple-backticks; the existing _extract_scope_from_design
    # below already uses the unescaped form, so this aligns the two.
    if ! grep -q '^```scope' "$output_design_md" 2>/dev/null; then
        warn "_design_stage_run_inner: design.md missing scope block — design output incomplete"
        emit_event "plugin.run.error" "plugin=design" "reason=missing_scope_block"
        return 1
    fi

    # Atomically finalize design.md (#507 contract).
    cat "$output_design_md" | atomic_write "$output_design_md"

    emit_event "plugin.run.complete" "stage=design" \
        "plugin=design" \
        "artifact=design.md"

    return 0
}

# _extract_scope_from_design <design_md_path>
# Parses the ```scope fenced block from design.md and returns a CSV of file
# paths on stdout. Strips blank lines. Returns empty string when no block found.
# legacy-citation: pipeline-stages.sh:38-71 (_extract_scope_from_design)
_extract_scope_from_design() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0

    local in_block=0
    local -a files=()
    while IFS= read -r line; do
        if [[ "$line" == '```scope' ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            break
        fi
        if [[ $in_block -eq 1 && -n "$line" ]]; then
            files+=("$line")
        fi
    done < "$design_md"

    if [[ ${#files[@]} -gt 0 ]]; then
        local IFS=','
        printf '%s' "${files[*]}"
    fi
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
