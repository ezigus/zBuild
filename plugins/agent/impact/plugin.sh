#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/impact — Impact Analyzer Stage (Wave 19-J, #744)           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Wraps the plan stage in plan_impact_cycle. Consumes plan.json + scope
# manifest; uses LLM judgment + Grep tool calls to trace which test/config
# files the plan's modifications would invalidate but aren't listed in any
# step.files[]. Emits impact.json { verdict: complete | incomplete, ... }
# and impact_feedback.md for cycle feedback wiring back into plan.
#
# Forward-compat: the input contract is "any plan-shaped artifact with
# steps[] each having files[]." When test_plan + arch_plan + coder_plan
# ship later with a plan_merger producing unified_plan.json, this plugin
# processes it identically — no impact-layer changes needed.

[[ -n "${_ZBUILD_IMPACT_LOADED:-}" ]] && return 0
_ZBUILD_IMPACT_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_IMPACT_DIR="$_ZBUILD_PLUGIN_DIR"
_IMPACT_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_IMPACT_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_IMPACT_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_IMPACT_ROOT/core/router/route.sh"

# ─── init ───────────────────────────────────────────────────────────────────
impact_init() {
    export ZBUILD_PLUGIN="impact"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=impact"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
impact_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "impact_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    _impact_run_inner \
        "$state_dir/scope-manifest.md" \
        "$artifacts_dir/plan.json" \
        "$artifacts_dir/impact.json" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan.json path
#   $3 = output impact.json path
#   $4 = artifact_dir (for intermediate files)
_impact_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local output_impact_json="$3"
    local artifact_dir="${4:-$(dirname "$output_impact_json")}"

    if [[ -z "$scope_manifest" || -z "$plan_json_path" || -z "$output_impact_json" ]]; then
        error "_impact_run_inner: requires <scope_manifest> <plan_json_path> <output_impact_json> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    if [[ ! -f "$plan_json_path" ]]; then
        error "_impact_run_inner: plan.json not found at $plan_json_path"
        emit_event "plugin.run.error" "plugin=impact" "reason=missing_plan_json"
        return 2
    fi

    local plan_content
    plan_content="$(cat "$plan_json_path")"

    # ─── Build prompt ────────────────────────────────────────────────────────
    local _impact_instructions
    _impact_instructions="$(cat <<'IMPACT_PROMPT'
You are an Impact Analyzer agent. Your job is to verify that a plan's
declared scope (steps[].files[]) is COMPLETE — that it lists every file
the plan's modifications would invalidate or require updating.

Tool use:
- You MAY use the Read tool to inspect files referenced in the plan.
- You MAY use the Grep tool to search the repo for symbols and references.
- Do NOT call Edit, Write, or Bash. This stage is read-only.

Output contract:
- Your FINAL response must be a SINGLE JSON object — no markdown code fences,
  no commentary before or after the JSON.

Required JSON schema:

  {
    "schema_version": 1,
    "verdict": "complete" | "incomplete",
    "missing": [
      {
        "step_id": "<id of the plan step that needs expanded scope>",
        "files_to_add": ["<repo-relative path>", "..."],
        "reason": "<why these files need to be in scope>"
      }
    ],
    "impact_feedback_md": "<markdown report fed back to the plan agent on the next cycle iter>"
  }

Rules:
- For each plan step.files[] entry, identify symbols defined in those files
  (function names, exported variables, template stage IDs, etc).
- Grep the repo for those symbols. Find files NOT already listed in any
  step.files[] that reference them.
- For each gap, add an entry to missing[] with the step_id, the files
  to add, and a one-line reason.
- If no gaps found, return verdict="complete" with missing=[].
- The impact_feedback_md is what the plan agent will read on iter N+1 if
  you returned incomplete. Make it actionable: name the missing files
  per step, cite the symbol or reference that linked them.

PLAN:
IMPACT_PROMPT
)"

    local prompt
    printf -v prompt '%s\n%s\n' "$_impact_instructions" "$plan_content"

    local prompt_file="$artifact_dir/impact-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"

    # ─── Redaction chokepoint (REQUIRED — ADR-004) ──────────────────────────
    local redacted_prompt_file="$artifact_dir/impact-prompt.redacted.txt"
    if ! apply_scope_redaction "$prompt_file" "$redacted_prompt_file" "$scope_manifest" "" "0"; then
        error "_impact_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=impact" "reason=redaction_failed"
        return 1
    fi

    local redacted_prompt
    redacted_prompt="$(cat "$redacted_prompt_file")"

    # ─── Route to LLM (T1 default per manifest) ─────────────────────────────
    local tier="${ZBUILD_IMPACT_TIER:-T1}"
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1

    set +e
    raw_response="$(route_to_model "$tier" "$redacted_prompt")"
    router_rc=$?
    set -e

    if [[ "$_prev_json_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
    fi

    if [[ $router_rc -ne 0 ]]; then
        error "_impact_run_inner: router rc=$router_rc"
        emit_event "plugin.run.error" "plugin=impact" "reason=router_rc_nonzero" "router_rc=$router_rc"
        return 1
    fi

    # Extract JSON object from response.
    local impact_json=""
    if [[ -n "$raw_response" ]]; then
        impact_json="$(printf '%s' "$raw_response" | extract_first_json_object 2>/dev/null || true)"
    fi

    if [[ -z "$impact_json" ]]; then
        error "_impact_run_inner: empty or malformed response from LLM"
        emit_event "plugin.run.error" "plugin=impact" "reason=empty_response"
        return 1
    fi

    # Validate verdict field.
    local verdict
    verdict="$(printf '%s' "$impact_json" | jq -r '.verdict // empty' 2>/dev/null || true)"
    if [[ "$verdict" != "complete" && "$verdict" != "incomplete" ]]; then
        warn "_impact_run_inner: invalid verdict '$verdict', defaulting to incomplete"
        impact_json="$(printf '%s' "$impact_json" | jq '. + {verdict:"incomplete"}' 2>/dev/null || echo "$impact_json")"
        verdict="incomplete"
    fi

    # Write impact.json
    printf '%s\n' "$impact_json" | atomic_write "$output_impact_json"

    # Extract and write impact_feedback.md sibling for cycle feedback wiring.
    local feedback_md
    feedback_md="$(printf '%s' "$impact_json" | jq -r '.impact_feedback_md // ""' 2>/dev/null || true)"
    printf '%s\n' "$feedback_md" > "$artifact_dir/impact_feedback.md"

    # Emit verdict event for cycle predicate consumption.
    case "$verdict" in
        complete)
            emit_event "impact.verdict.complete" "plugin=impact" "artifact=impact.json"
            ;;
        incomplete)
            local missing_count
            missing_count="$(printf '%s' "$impact_json" | jq -r '.missing | length' 2>/dev/null || echo 0)"
            emit_event "impact.verdict.incomplete" "plugin=impact" "artifact=impact.json" "missing_count=${missing_count:-0}"
            # Per-gap scope.expanded event for postmortem discoverability.
            local _idx
            for _idx in $(printf '%s' "$impact_json" | jq -r '.missing | keys[]?' 2>/dev/null || true); do
                local _step_id _files
                _step_id="$(printf '%s' "$impact_json" | jq -r --argjson i "$_idx" '.missing[$i].step_id' 2>/dev/null || echo unknown)"
                _files="$(printf '%s' "$impact_json" | jq -r --argjson i "$_idx" '.missing[$i].files_to_add | join(",")' 2>/dev/null || echo "")"
                emit_event "impact.scope.expanded" "plugin=impact" \
                    "step_id=$_step_id" "files_to_add=${_files:-none}" 2>/dev/null || true
            done
            ;;
    esac

    emit_event "plugin.run.complete" "stage=impact" \
        "plugin=impact" "verdict=$verdict" "artifact=impact.json"
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
impact_finalize() {
    emit_event "plugin.finalize.complete" "plugin=impact"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
impact_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=impact"
    return 0
}
