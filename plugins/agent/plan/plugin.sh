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
# ADR-028: shared LLM-agent stage framework (PR 2/5 — plan migration).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_PLAN_ROOT/scripts/lib/llm-agent.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_PLAN_ROOT/scripts/lib/prompt-overrides.sh"

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

# ─── _plan_validate_dod_discipline ──────────────────────────────────────────
# Wave 19-F (#738): validate the produced plan against the issue body's
# Definition-of-done / Anti-patterns / 5-test trial discipline. Returns 0
# if the plan honors the operational requirements, 1 otherwise. Side
# effects: emits plan.dod_violation or plan.flow_wiring_missing events
# describing the gap so the operator can see exactly which rule fired.
#
# Args:
#   $1 = plan_json (string content, valid JSON per schema)
#   $2 = goal_text (raw issue body the plan was decomposed from)
_plan_validate_dod_discipline() {
    local plan_json="$1"
    local goal_text="$2"

    if [[ -z "$plan_json" || -z "$goal_text" ]]; then
        return 0
    fi

    # Detect issue-body sections that trigger discipline.
    local has_dod=0 has_5test=0 has_antipatterns=0
    if printf '%s' "$goal_text" | grep -Eqi '^#+[[:space:]]*(Definition of done|Acceptance criteria)\b'; then
        has_dod=1
    fi
    if printf '%s' "$goal_text" | grep -Eqi '^#+[[:space:]]*5-test trial\b'; then
        has_5test=1
    fi
    if printf '%s' "$goal_text" | grep -Eqi '^#+[[:space:]]*Anti-patterns\b'; then
        has_antipatterns=1
    fi

    # No operational sections → no enforcement.
    if [[ $has_dod -eq 0 && $has_5test -eq 0 && $has_antipatterns -eq 0 ]]; then
        return 0
    fi

    # Flatten plan steps + notes into a single searchable blob.
    local plan_blob=""
    plan_blob="$(printf '%s' "$plan_json" | jq -r '
        [(.title // ""),
         (.notes // ""),
         (.steps // [] | map(.description // "") | join("\n"))
        ] | join("\n")' 2>/dev/null || true)"

    # Forbidden-phrase enforcement (DoD or Anti-patterns).
    # Each alternative matches independently — `optional` alone is a hit,
    # `gated by config` alone is a hit. Word-boundary anchored where
    # plausible to avoid spurious matches against benign use ("optionally").
    if [[ $has_dod -eq 1 || $has_antipatterns -eq 1 ]]; then
        local _forbidden_re='may be toggled off|may be disabled|declared but disabled|gated by config|future follow-up|may be optional|\boptional\b'
        if printf '%s' "$plan_blob" | grep -Eqi "$_forbidden_re"; then
            local _matched
            _matched="$(printf '%s' "$plan_blob" | grep -Eoi "$_forbidden_re" | head -1)"
            emit_event "plan.dod_violation" "plugin=plan" \
                "reason=forbidden_phrase" "phrase=${_matched:-unknown}" \
                2>/dev/null || true
            return 1
        fi
    fi

    # Anti-pattern matching against per-issue patterns (any quoted string
    # after a ❌ marker in the Anti-patterns section). The awk range walks
    # from the Anti-patterns header forward until either the NEXT header
    # of equal-or-shallower depth OR EOF. Using only `/^#+[[:space:]]/` as
    # the end pattern incorrectly matches the start header itself,
    # collapsing the range to a single line. Track whether we've seen the
    # opening header so we don't immediately close on it.
    if [[ $has_antipatterns -eq 1 ]]; then
        local _patterns
        _patterns="$(printf '%s' "$goal_text" | awk '
            BEGIN { in_section=0 }
            /^#+[[:space:]]*Anti-patterns/ { in_section=1; next }
            in_section && /^#+[[:space:]]/ { in_section=0; next }
            in_section { print }
        ' | grep -Eo '❌[[:space:]]*"[^"]+"' | sed 's/^❌[[:space:]]*"//; s/"$//' | head -20)"
        local _ap
        while IFS= read -r _ap; do
            [[ -z "$_ap" ]] && continue
            if printf '%s' "$plan_blob" | grep -Fqi "$_ap"; then
                emit_event "plan.dod_violation" "plugin=plan" \
                    "reason=anti_pattern_match" "pattern=$_ap" \
                    2>/dev/null || true
                return 1
            fi
        done <<< "$_patterns"
    fi

    # Migration-keeper enforcement: if 5-test trial present, plan MUST touch
    # config/templates/standard.yaml (or any file under config/templates/).
    if [[ $has_5test -eq 1 ]]; then
        local _touches_template=0
        if printf '%s' "$plan_json" | jq -r '.steps // [] | map(.files // []) | flatten | .[]' 2>/dev/null | grep -Eq '^config/templates/'; then
            _touches_template=1
        fi
        if [[ $_touches_template -eq 0 ]]; then
            emit_event "plan.flow_wiring_missing" "plugin=plan" \
                "reason=no_template_change" \
                2>/dev/null || true
            return 1
        fi
    fi

    return 0
}

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
    # ADR-028: canonical OUTPUT CONTRACT block from framework. Plan has no
    # `.verdict` field so verdicts=none (omits the enum line and decouples
    # validation from a verdict assumption).
    local _plan_schema
    _plan_schema="$(cat <<'PLAN_SCHEMA'
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
PLAN_SCHEMA
)"
    local _output_contract_block
    _output_contract_block="$(_llm_output_contract \
        --stage plan \
        --verdicts none \
        --schema-json "$_plan_schema")"

    local _plan_instructions
    _plan_instructions="$(cat <<'PLAN_PROMPT'
You are a software planning agent. Decompose the goal into concrete
implementation steps.

Tool use:
- You may use the Read tool to inspect files within the scope-manifest
  before producing the plan. Read only paths under the scope-manifest
  prefixes listed at the end of this prompt.
- Do NOT call Edit, Write, or Bash. This stage is read-only.

Rules:
- `schema_version` MUST be the integer 1.
- `steps` MUST be a non-empty array; each step MUST have id, description,
  files, estimated_lines.
- Step ids are stable handles ("step-1", "step-2", ...) in declaration order.
- `files` lists every file the step expects to create or modify; every
  entry MUST be a string repo-relative path under a scope-manifest prefix.
- Keep steps small and independently testable.

## Issue-body discipline (Wave 19-F, #738)

If the goal text contains sections titled "Definition of done", "Acceptance
criteria", "Anti-patterns", or "5-test trial" (or similar operational
checklists), you MUST honor the following:

1. Treat every Definition-of-done checkbox as a hard requirement. Each step
   in your plan MUST contribute to satisfying at least one DoD checkbox,
   and your plan in aggregate MUST satisfy all DoD checkboxes. Steps that
   leave any DoD item unmet are invalid — reject your own draft and re-plan.

2. Refuse any step that matches an Anti-pattern enumerated in the issue.
   If a reasonable-sounding step seems to match an Anti-pattern, that
   proves you've misread the issue — add a note in `notes` requesting
   clarification rather than producing a plan that violates the
   Anti-pattern.

3. Do not invent permissions the issue body doesn't grant. If the issue is
   silent about whether something is optional, gated, or deferrable, treat
   it as required. The plan MUST NOT contain phrases like "may be toggled
   off", "optional", "gated by config", "future follow-up", or
   "declared but disabled" unless the issue body explicitly grants that
   latitude.

4. For migration keepers (issues with a "5-test trial" section or that cite
   KEEPERS §), the plan MUST wire the migrated code into the live execution
   path. Plans that create scaffolding (manifests, plugin directories,
   stage sections) without modifying the actual dispatched flow are invalid.
   Concretely: if the issue migrates stage X, the plan MUST include a step
   that modifies `config/templates/standard.yaml` (or its referenced
   template) so X appears in the live `flow:` and runs in a dogfood.

Goal:
PLAN_PROMPT
)"
    # Prepend the framework-rendered OUTPUT CONTRACT block (ADR-028).
    _plan_instructions="$_output_contract_block

$_plan_instructions"
    # Inline the scope-manifest verbatim (ground truth). Falls back to a
    # placeholder if the manifest file is unreadable so the prompt remains
    # well-formed; redaction has already fail-closed in that case above.
    local manifest_body=""
    if [[ -f "$scope_manifest" ]]; then
        manifest_body="$(cat "$scope_manifest")"
    fi
    local prompt=""
    prompt+="$_plan_instructions"$'\n'
    prompt+="$redacted_content"$'\n\n'
    prompt+=$'Scope manifest (allowed path prefixes):\n'
    prompt+="$manifest_body"$'\n'

    # ADR-032 (#855): plan assembles its prompt in $prompt AFTER the goal is
    # redacted, so the override is redacted in its OWN pass and spliced in AFTER
    # the contract (_plan_instructions) — preserving both invariants: the
    # override is redaction-covered and follows the shipped charter.
    local _plan_ov; _plan_ov="$(load_prompt_override "plan")"
    if [[ -n "$_plan_ov" ]]; then
        local _ov_in="$artifact_dir/plan-override.txt"
        local _ov_red="$artifact_dir/plan-override.redacted.txt"
        printf '%s\n' "$_plan_ov" > "$_ov_in"
        if apply_scope_redaction "$_ov_in" "$_ov_red" "$scope_manifest" "" "0"; then
            prompt+=$'\n\n'"$ZBUILD_PROMPT_OVERRIDE_DELIMITER"$'\n\n'
            prompt+="$(cat "$_ov_red")"$'\n'
        fi
    fi

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

    # Wave 19-F (#738): DoD discipline check. Fail-soft like scope_violations
    # so the plan.json reaches review for verdict; the diagnostic event
    # gives review explicit signal to request_changes.
    local dod_discipline_pass=1
    if ! _plan_validate_dod_discipline "$plan_json" "$redacted_content"; then
        dod_discipline_pass=0
    fi

    emit_event "plugin.run.complete" "stage=plan" \
        "plugin=plan" \
        "step_count=$step_count" \
        "scope_violations=$scope_violations" \
        "dod_discipline_pass=$dod_discipline_pass" \
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
