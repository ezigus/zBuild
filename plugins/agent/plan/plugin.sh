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
#   plan_cleanup     — emit plugin.cleanup.complete, return 0

[[ -n "${_ZBUILD_PLAN_LOADED:-}" ]] && return 0
_ZBUILD_PLAN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_PLAN_DIR="$_ZBUILD_PLUGIN_DIR"
_PLAN_ROOT="$_ZBUILD_PLUGIN_ROOT"
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
    # Do not pre-check scope_manifest existence — apply_scope_redaction handles
    # the missing-manifest fail-closed path (ADR-004) and the operator override.

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

    # Build prompt from redacted goal. The instruction block declares the
    # plan.json schema inline because the validator below (jq -e at the
    # response-parse step) enforces `schema_version=1` and a non-empty
    # `steps[]`, and an underspecified prompt makes the LLM return prose
    # (issue #435). Schema mirrors the canonical fixture at
    # plugins/agent/plan/tests/plan-test.sh.
    #
    # The static instruction block is captured via single-quoted heredoc
    # (no expansion); the dynamic goal is appended with an explicit \n
    # separator (printf instead of $(...)) so the boundary is not eaten
    # by command-substitution trailing-newline stripping.
    local _plan_instructions
    _plan_instructions="$(cat <<'PLAN_PROMPT'
You are a software planning agent. Decompose the goal into concrete
implementation steps. Respond with a SINGLE JSON object and nothing else
— no markdown code fences, no commentary before or after, no tool calls.

Required JSON schema:

  {
    "schema_version": 1,
    "title": "<short title>",
    "goal": "<one-line restatement of the goal>",
    "steps": [
      {
        "id": "step-1",
        "description": "<what this step accomplishes>",
        "files": ["<repo-relative path>", "..."],
        "estimated_lines": <integer>
      }
    ],
    "estimated_total_lines": <integer>,
    "notes": "<optional caveats; empty string if none>"
  }

Rules:
- `schema_version` MUST be the integer 1.
- `steps` MUST be a non-empty array; each step MUST have id, description,
  files, estimated_lines.
- Step ids are stable handles ("step-1", "step-2", ...) in declaration order.
- `files` lists every file the step expects to create or modify.
- Keep steps small and independently testable.
- Do not include reasoning, plans-about-plans, or repo exploration — just
  the JSON describing what to do.

Goal:
PLAN_PROMPT
)"
    local prompt
    printf -v prompt '%s\n%s\n' "$_plan_instructions" "$redacted_content"

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
        if printf '%s' "$stripped" | jq -e 'type == "object" and (.schema_version == 1) and (.steps | type == "array") and (.steps | length > 0)' >/dev/null 2>&1; then
            plan_json="$stripped"
        else
            warn "_plan_run_inner: LLM response is not a valid plan.json (requires schema_version=1 and non-empty .steps)"
        fi
    elif [[ $router_rc -eq 1 ]]; then
        warn "_plan_run_inner: router rc=1 (recoverable); no plan produced"
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

    emit_event "plugin.run.complete" "stage=plan" \
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
    emit_event "plugin.cleanup.complete" "plugin=plan"
    return 0
}
