#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/plan — Plan stage agent (issue #340)                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: plan (ADR-013, T2, blocking)
# Produces: state/artifacts/plan.json
#
# Lifecycle:
#   plan_init        — set env vars, emit plugin.init.start
#   plan_run         — derive paths, delegate to _plan_run_inner
#   _plan_run_inner  — redact → route → validate → emit stage.complete
#   plan_finalize    — emit plugin.finalize.complete
#   plan_cleanup     — emit plugin.cleanup.done, return 0

[[ -n "${_ZBUILD_PLAN_LOADED:-}" ]] && return 0
_ZBUILD_PLAN_LOADED=1

_PLAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLAN_ROOT="$(cd "$_PLAN_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$_PLAN_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_PLAN_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PLAN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_PLAN_ROOT/core/router/route.sh"

# ─── init ───────────────────────────────────────────────────────────────────
plan_init() {
    export ZBUILD_PLUGIN="plan"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=plan"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: plan_run(stage, state_file)
# Derives artifact paths from state_dir and delegates to the inner function.
plan_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "plan_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local scope_manifest="$state_dir/scope-manifest.md"
    if [[ ! -f "$scope_manifest" ]]; then
        error "plan_run: scope-manifest.md not found at $scope_manifest"
        return 2
    fi

    local goal_text="${ZBUILD_GOAL:-}"
    if [[ -z "$goal_text" ]]; then
        if [[ -f "$state_dir/intake.md" ]]; then
            goal_text="$(cat "$state_dir/intake.md")"
        fi
    fi
    if [[ -z "$goal_text" ]]; then
        error "plan_run: ZBUILD_GOAL is unset and $state_dir/intake.md is missing or empty"
        return 2
    fi

    _plan_run_inner \
        "$scope_manifest" \
        "$goal_text" \
        "$artifacts_dir/plan.json" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = goal text (raw string)
#   $3 = output plan.json path
#   $4 = artifact dir for intermediate files
_plan_run_inner() {
    local scope_manifest="$1"
    local goal_text="$2"
    local output_plan_json="$3"
    local artifact_dir="${4:-$(dirname "$output_plan_json")}"

    if [[ -z "$scope_manifest" || -z "$goal_text" || -z "$output_plan_json" ]]; then
        error "_plan_run_inner: requires <scope_manifest> <goal_text> <output_plan_json> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    # Write goal text to a temp input file for the redaction chokepoint.
    local goal_input_file="$artifact_dir/plan-goal.txt"
    printf '%s\n' "$goal_text" > "$goal_input_file"

    local redacted_file="$artifact_dir/plan-prompt.redacted.txt"

    # ─── Redaction chokepoint (REQUIRED — ADR-004) ──────────────────────────
    if ! apply_scope_redaction "$goal_input_file" "$redacted_file" "$scope_manifest" "" "0"; then
        error "_plan_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=plan" "reason=redaction_failed"
        return 1
    fi

    local redacted_content
    redacted_content="$(cat "$redacted_file")"

    # Build prompt from redacted goal.
    local prompt
    prompt="$(printf '%s\n\n%s\n' \
        "You are a software planning agent. Given the following goal, produce a structured plan in JSON." \
        "$redacted_content")"

    # ─── Route to LLM (T2, matching manifest config.tier_default) ───────────
    local tier="${ZBUILD_PLAN_TIER:-T2}"
    local raw_response="" router_rc=0
    raw_response="$(route_to_model "$tier" "$prompt" 2>/dev/null)" || router_rc=$?

    # ─── Parse: strip fences, validate JSON with .steps array ───────────────
    local plan_json=""
    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        local stripped
        stripped="$(printf '%s' "$raw_response" \
            | sed 's/^[[:space:]]*```json[[:space:]]*//' \
            | sed 's/^[[:space:]]*```[[:space:]]*//'     \
            | sed 's/[[:space:]]*```[[:space:]]*$//')"
        if printf '%s' "$stripped" | jq -e 'type == "object" and (.steps | type == "array") and (.steps | length > 0)' >/dev/null 2>&1; then
            plan_json="$stripped"
        else
            warn "_plan_run_inner: LLM response is not a valid plan JSON with non-empty .steps; using stub"
        fi
    elif [[ $router_rc -eq 1 ]]; then
        warn "_plan_run_inner: router rc=1 (recoverable); using stub plan"
    elif [[ $router_rc -ne 0 ]]; then
        error "_plan_run_inner: router rc=$router_rc (fatal)"
        emit_event "plugin.run.error" "plugin=plan" \
            "reason=router_fatal" "router_rc=$router_rc"
        return 1
    fi

    # ─── Validate: fail if we still have no usable plan ─────────────────────
    if [[ -z "$plan_json" ]]; then
        error "_plan_run_inner: no valid plan.json produced (LLM returned unusable response)"
        emit_event "plugin.run.error" "plugin=plan" "reason=invalid_plan_response"
        return 1
    fi

    # ─── Write plan.json ─────────────────────────────────────────────────────
    printf '%s\n' "$plan_json" | atomic_write "$output_plan_json"

    local step_count
    step_count="$(printf '%s' "$plan_json" | jq '.steps | length' 2>/dev/null || echo 0)"

    emit_event "stage.complete" "stage=plan" \
        "plugin=plan" \
        "step_count=$step_count" \
        "artifact=plan.json"
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
plan_finalize() {
    emit_event "plugin.finalize.complete" "plugin=plan"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
plan_cleanup() {
    emit_event "plugin.cleanup.done" "plugin=plan"
    return 0
}
