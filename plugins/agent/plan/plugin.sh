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

# ─── _plan_validate_scope ───────────────────────────────────────────────────
# Walk plan.json's steps[].files[] and emit one plan.scope.violation event per
# offending path. Fail-soft: prints the violation count to stdout (caller adds
# it to plugin.run.complete) and returns 0 even when violations are found.
# Args:
#   $1 = plan_json (string content)
#   $2 = scope_manifest path
# Stdout: integer violation count.
_plan_validate_scope() {
    local plan_json="$1"
    local manifest="$2"

    if [[ -z "$plan_json" || ! -f "$manifest" ]]; then
        printf '0'
        return 0
    fi

    # Reuse the manifest parser shape from core/redaction/scope-redaction.sh:75.
    local allow_lines
    allow_lines="$(awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' "$manifest")"

    local scope_hash; scope_hash="$(shasum -a 256 "$manifest" | cut -d' ' -f1)"
    local manifest_abs; manifest_abs="$(cd "$(dirname "$manifest")" 2>/dev/null && pwd)/$(basename "$manifest")"

    local violations=0
    # Stream "step_id<TAB>file" pairs. Use TSV to keep paths intact.
    while IFS=$'\t' read -r step_id raw_path; do
        [[ -z "$step_id" || -z "$raw_path" ]] && continue
        local reason=""
        # Absolute path?
        if [[ "$raw_path" == /* ]]; then
            reason="absolute_path"
        else
            # Normalize: strip leading ./
            local norm="$raw_path"
            norm="${norm#./}"
            # Traversal — any `..` segment escapes the repo.
            if [[ "$norm" == ".." || "$norm" == "../"* || "$norm" == *"/../"* || "$norm" == *"/.." ]]; then
                reason="out_of_repo"
            else
                # Prefix-match against allowlist
                local in_scope=0 prefix
                while IFS= read -r prefix; do
                    [[ -z "$prefix" ]] && continue
                    if [[ "$norm" == "$prefix"* || "./$norm" == "$prefix"* ]]; then
                        in_scope=1
                        break
                    fi
                done <<< "$allow_lines"
                [[ "$in_scope" -eq 0 ]] && reason="out_of_scope"
            fi
        fi
        if [[ -n "$reason" ]]; then
            violations=$((violations + 1))
            emit_event "plan.scope.violation" \
                "plugin=plan" \
                "stage=plan" \
                "step_id=$step_id" \
                "path=$raw_path" \
                "reason=$reason" \
                "scope_hash=$scope_hash" \
                "manifest_path=$manifest_abs"
        fi
    done < <(printf '%s' "$plan_json" \
        | jq -r '.steps[]? | .id as $id | (.files[]? | select(type=="string")) as $f | [$id, $f] | @tsv' 2>/dev/null || true)

    printf '%s' "$violations"
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
    # ADR-018 Pattern 1 (#468): plan runs as one-shot with tools available.
    # Invite Read for context-gathering inside the scope-manifest; forbid
    # mutating tools. Inline the scope-manifest verbatim as ground truth so
    # the LLM does not hallucinate paths. Pipeline post-validates files[].
    local _plan_instructions
    _plan_instructions="$(cat <<'PLAN_PROMPT'
You are a software planning agent. Decompose the goal into concrete
implementation steps.

Tool use:
- You may use the Read tool to inspect files within the scope-manifest
  before producing the plan. Read only paths under the scope-manifest
  prefixes listed at the end of this prompt.
- Do NOT call Edit, Write, or Bash. This stage is read-only.

Output contract:
- Your FINAL response must be a SINGLE JSON object — no markdown code fences,
  no commentary before or after the JSON.
- Your response MUST begin with `{` and contain nothing other than the JSON object — no leading prose, no trailing prose, no markdown fences.

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
- `files` lists every file the step expects to create or modify; every
  entry MUST be a string repo-relative path under a scope-manifest prefix.
- Keep steps small and independently testable.

Goal:
PLAN_PROMPT
)"
    # Inline the scope-manifest verbatim (ground truth). Falls back to a
    # placeholder if the manifest file is unreadable so the prompt remains
    # well-formed; redaction has already fail-closed in that case above.
    local manifest_body=""
    if [[ -f "$scope_manifest" ]]; then
        manifest_body="$(cat "$scope_manifest")"
    fi
    local prompt
    printf -v prompt '%s\n%s\n\nScope manifest (allowed path prefixes):\n%s\n' \
        "$_plan_instructions" "$redacted_content" "$manifest_body"

    # ─── Route to LLM (T2, matching manifest config.tier_default) ───────────
    # ADR-018 (#476): Pattern 1 stages with tools MUST use JSON envelope mode.
    # Headless text mode streams every turn (reasoning + tools + final) as
    # concatenated text; only .result from the JSON envelope is the
    # final assistant message. Without this, reasoning turns leak as a prose
    # preamble and break the strict-JSON parser below.
    #
    # Save/restore so a caller that set the flag externally is not clobbered.
    local tier="${ZBUILD_PLAN_TIER:-T2}"
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # ADR-018 (#483): tag the router's capture so plan's own banner renders
    # the plan.json output via render_plan_md (mirror #476 save/restore).
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_ARTIFACT_ID=plan
    # #491: do NOT redirect route_to_model's stderr — the stage-io input banner
    # writes to fd 2 (ZBUILD_STAGE_IO_FD default) and 2>/dev/null would swallow
    # it, breaking the ADR-015 §v4 input-before-action ordering contract.
    raw_response="$(route_to_model "$tier" "$prompt")" || router_rc=$?
    if [[ "$_prev_json_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
    fi
    if [[ "$_prev_artifact_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_ARTIFACT_ID
    else
        export ZBUILD_ROUTER_ARTIFACT_ID="$_prev_artifact_env"
    fi

    # ─── Parse: strip fences, validate JSON with .steps array ───────────────
    local plan_json=""
    # #476: distinguish empty-envelope from schema-failure so a future
    # regression (e.g. envelope mode silently disabled) emits a different
    # `reason=` and is grep-detectable.
    local schema_failed=0
    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        # #478: slice the LAST top-level balanced JSON object out of any
        # prose preface the model may emit inside the final assistant turn
        # (envelope mode separates turns but not in-turn prose). Helper
        # passes input through verbatim on no-match so the #476 reason=
        # diagnostics below still classify schema_violation vs empty.
        local stripped
        stripped="$(printf '%s' "$raw_response" | extract_first_json_object)"
        if printf '%s' "$stripped" | jq -e 'type == "object" and (.schema_version == 1) and (.steps | type == "array") and (.steps | length > 0) and (.steps | all((.files | type == "array") and (.files | all(type == "string"))))' >/dev/null 2>&1; then
            plan_json="$stripped"
        else
            schema_failed=1
            warn "_plan_run_inner: LLM response is not a valid plan.json (requires schema_version=1 and non-empty .steps)"
        fi
    elif [[ $router_rc -eq 0 && -z "$raw_response" ]]; then
        warn "_plan_run_inner: router rc=0 but .result envelope is empty (model returned no final message)"
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
        local _reason="invalid_plan_response"
        [[ $router_rc -eq 0 && -z "$raw_response" ]] && _reason="empty_result_envelope"
        [[ $schema_failed -eq 1 ]] && _reason="schema_violation"
        error "_plan_run_inner: no valid plan.json produced (reason=$_reason)"
        emit_event "plugin.run.error" "plugin=plan" "reason=$_reason"
        return 1
    fi

    # ─── Write plan.json ─────────────────────────────────────────────────────
    printf '%s\n' "$plan_json" | atomic_write "$output_plan_json"

    local step_count
    step_count="$(printf '%s' "$plan_json" | jq '.steps | length' 2>/dev/null || echo 0)"

    # ADR-018 Pattern 1 (#468): post-validate step.files[] against the
    # scope-manifest. Fail-soft — plan.json is written regardless; review
    # verdicts on violations rather than aborting the pipeline.
    local scope_violations
    scope_violations="$(_plan_validate_scope "$plan_json" "$scope_manifest")"
    [[ -z "$scope_violations" ]] && scope_violations=0

    emit_event "plugin.run.complete" "stage=plan" \
        "plugin=plan" \
        "step_count=$step_count" \
        "scope_violations=$scope_violations" \
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
