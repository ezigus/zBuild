#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/plan — Plan stage agent (issue #340)                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: plan (ADR-013, T2, blocking)
# Produces: state/artifacts/plan.json
#
# Lifecycle:
#   plan_run         — derive paths, delegate to _plan_run_inner
#   _plan_run_inner  — redact → route → validate → emit stage.complete
#   plan_cleanup     — emit plugin.cleanup.complete, return 0

[[ -n "${_ZBUILD_PLAN_LOADED:-}" ]] && return 0
_ZBUILD_PLAN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_PLAN_DIR="$_ZBUILD_PLUGIN_DIR"
_PLAN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PLAN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_PLAN_ROOT/core/router/route.sh"
# ADR-028: shared LLM-agent stage framework (PR 2/5 — plan migration).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_PLAN_ROOT/scripts/lib/llm-agent.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_PLAN_ROOT/scripts/lib/prompt-overrides.sh"
# #721: strip OOS-marker tags and ANSI from goal text before LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_PLAN_ROOT/scripts/lib/test-output-sanitize.sh"
# #1052: durable plan-context cache + max_turns envelope recovery (EPIC #966).
# shellcheck source=../../../scripts/lib/plan-context.sh
source "$_PLAN_ROOT/scripts/lib/plan-context.sh"
# #1052: router rc → verdict/reason classifier (shared with impact).
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_PLAN_ROOT/scripts/lib/router-rc-classify.sh"
# ADR-050 (#1581): unified prior-work seam — seed from a prior run's plan.json.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_PLAN_ROOT/scripts/lib/prior-output-reader.sh"
# Persona resolver + stage/lens composition seam (#1304, #1393).
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_PLAN_ROOT/core/plugin-registry/registry.sh"

# _plan_budget_guidance <max_turns> — the turn-budget guardrail injected into the
# planner prompt (#1442). Empty for the 0 (unlimited) sentinel or a non-numeric
# value, so an uncapped plan stage reads exactly as before. With a finite budget
# the planner is told its budget and biased to CONVERGE: emit a best-effort plan
# before it runs out rather than exhausting the budget mid-exploration (which
# yielded NO plan at all and left the cross-run cache nothing to carry forward).
_plan_budget_guidance() {
    local budget="${1:-}"
    [[ "$budget" =~ ^[0-9]+$ && "$budget" -gt 0 ]] || { printf ''; return 0; }
    cat <<EOF
TURN BUDGET (read this — you have a BOUNDED tool-call budget):
- You have about ${budget} tool-call turns for BOTH exploration AND emitting the plan.
- Producing a usable plan is the objective; exhaustive exploration is not. A plan
  built from partial understanding, with the gaps noted in \`notes\`, BEATS running
  out of turns and producing no plan at all.
- Explore with TARGETED reads/greps of specific files. Avoid whole-repo
  \`find | xargs grep\` sweeps — they flood your context and burn turns fast.
- STOP exploring and EMIT the plan JSON well before you run out. If you are running
  low, emit your best-effort plan NOW with assumptions in \`notes\` — never spend the
  whole budget exploring and finish with nothing.
EOF
}

# _plan_wallclock_guidance <budget_s> <elapsed_s> — wall-clock budget signal
# injected into the planner prompt (#1550). Empty when budget_s is not a
# positive integer or when elapsed_s >= budget_s (degenerate guard). Otherwise
# emits a "WALL CLOCK BUDGET" block telling the planner its total budget,
# elapsed time, and instructing it to emit a best-effort plan before the hard
# OS SIGTERM fires — orthogonal to the turn-budget guardrail from #1442.
_plan_wallclock_guidance() {
    local budget_s="${1:-}" elapsed_s="${2:-}"
    [[ "$budget_s" =~ ^[0-9]+$ && "$budget_s" -gt 0 ]] || { printf ''; return 0; }
    [[ "$elapsed_s" =~ ^[0-9]+$ ]] || elapsed_s=0
    [[ "$elapsed_s" -lt "$budget_s" ]] || { printf ''; return 0; }
    local _stop_at=$(( budget_s * 70 / 100 ))
    cat <<EOF
WALL CLOCK BUDGET (read this — the stage has a hard OS wall-clock timeout):
- This stage has a wall-clock budget of ${budget_s} seconds total; ~${elapsed_s}s have elapsed.
- You cannot read a real-time clock, but estimate elapsed time from your tool-call
  history (count of turns × typical latency per turn visible in your context window).
- Target emitting your best-effort plan before ~${_stop_at}s of wall-clock time has elapsed
  (70% of the ${budget_s}s budget). A partial plan with gaps in \`notes\` BEATS a hard
  SIGTERM that produces no output at all — never spend the full budget exploring.
EOF
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
    # Capture entry time for the wall-clock budget signal (#1550). $SECONDS is a
    # Bash builtin — no subshell, no subprocess latency, never drifts from real time.
    local _plan_start_s=$SECONDS

    # ADR-043: redaction is owned by the router (route_to_model) — it redacts the
    # assembled prompt below by construction. This stage assembles RAW text and
    # each spliced piece (goal, resumed context, operator override) rides that
    # single redaction pass.
    local goal_content
    # #721: strip ANSI codes / stray OOS-marker wrappers from the goal text.
    goal_content="$(printf '%s' "$goal_text" | _zbuild_sanitize_for_llm)"

    # Persona seam (#1393/#1572): open the prompt with the product-owner
    # persona's behavior framing when its manifest is present; when absent,
    # fall back to the behavior-only sentence (no role prefix) so the fallback
    # stays consistent with the persona-present path (#1568 behavior-first).
    local _task_intro="Decompose the goal into concrete implementation steps."
    local _framing _persona_fallback _persona_applied=0
    _persona_fallback="$_task_intro"
    _framing="$(persona_stage_framing product-owner "$_task_intro" "$_PLAN_ROOT/plugins" 2>/dev/null)" \
        && _persona_applied=1 \
        || { warn "plan: persona_stage_framing failed — using fallback framing"; _framing="$_persona_fallback"; }
    # Guard: rc=0 but empty output (e.g. perspective key absent in manifest).
    [[ -n "$_framing" ]] || { _framing="$_persona_fallback"; _persona_applied=0; }
    # _persona_applied now records whether the manifest resolved; the carrier var
    # ZBUILD_STAGE_IO_PERSONA is exported later (beside ZBUILD_ROUTER_ARTIFACT_ID,
    # just before route_to_model) so it shares the same save/restore window and
    # cannot leak past an early resolve_tier bail-out.

    # Build prompt from the goal. The instruction block declares the
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
Tool use:
- Explore with READ-ONLY tools (Read, Grep, Glob, and read-only Bash such as
  find/grep/cat/git-log) to inspect files within the scope-manifest before
  producing the plan. Keep exploration TARGETED and bounded (see TURN BUDGET).
- Do NOT call Edit or Write, and do NOT run any command that modifies the tree.
  This stage is read-only.

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
    # #1442: resolve the turn budget the router will enforce and tell the planner,
    # so it converges (emits a plan) before exhausting the budget mid-exploration.
    local _plan_budget="" _plan_budget_block=""
    if declare -F _route_resolve_max_turns >/dev/null 2>&1; then
        _plan_budget="$(ZBUILD_CURRENT_STAGE="${ZBUILD_CURRENT_STAGE:-plan}" _route_resolve_max_turns 2>/dev/null || true)"
    fi
    _plan_budget_block="$(_plan_budget_guidance "$_plan_budget")"
    # #1550: resolve the wall-clock timeout and inject a WALL CLOCK BUDGET signal
    # so the planner self-arrests before the OS SIGTERM fires (orthogonal to the
    # turn-budget guardrail: a slow T2 model can hit the wall-clock with turns left).
    local _plan_wc_budget="" _plan_wc_elapsed=0 _plan_wc_block=""
    if declare -F _route_resolve_timeout >/dev/null 2>&1; then
        _plan_wc_budget="$(ZBUILD_CURRENT_STAGE="${ZBUILD_CURRENT_STAGE:-plan}" _route_resolve_timeout 2>/dev/null || true)"
    fi
    _plan_wc_elapsed=$(( SECONDS - _plan_start_s ))
    _plan_wc_block="$(_plan_wallclock_guidance "$_plan_wc_budget" "$_plan_wc_elapsed")"
    # Prepend: OUTPUT CONTRACT (ADR-028), then persona framing (behavior first),
    # then budget guardrail (when a finite budget applies), then instructions.
    _plan_instructions="$_output_contract_block

$_framing
${_plan_budget_block:+
$_plan_budget_block
}${_plan_wc_block:+
$_plan_wc_block
}
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
    prompt+="$goal_content"$'\n\n'
    prompt+=$'Scope manifest (allowed path prefixes):\n'
    prompt+="$manifest_body"$'\n'

    # ─── Resume (Pillar B, #1052) ───────────────────────────────────────────
    # Before any operator override, look up a prior exhausted exploration for
    # THIS repo+scope+goal and splice it in. plan_context_read_for_resume gates
    # on ZBUILD_PLAN_RESUME != 0 AND goal_hash/repo_id/scope_manifest_ref match
    # AND status != complete; any mismatch echoes nothing / rc=1 → no splice.
    # The cached reasoning was redacted against the PRIOR run's manifest (which
    # may differ), so it gets its OWN redaction pass here — NEVER splice
    # unredacted cache (mirror the operator-override redaction below).
    local _resume_repo_id _resume_goal_hash _resume_scope_ref _resume_text
    _resume_repo_id="$(plan_context_repo_id)"
    _resume_goal_hash="$(plan_context_goal_hash "$goal_text")"
    if [[ -f "$scope_manifest" ]]; then
        _resume_scope_ref="$(shasum -a 256 "$scope_manifest" | cut -d' ' -f1)"
    else
        _resume_scope_ref="absent"
    fi
    # scope_key mirrors Pillar E: issue number when present, else manifest hash.
    local _resume_scope_key="${ZBUILD_ISSUE_NUMBER:-$_resume_scope_ref}"
    _resume_text="$(plan_context_read_for_resume \
        "$_resume_repo_id" "$_resume_scope_key" "$_resume_goal_hash" "$_resume_scope_ref" 2>/dev/null || true)"
    # Observability (#1052 review): when a cache leaf EXISTS for the computed key
    # but resume returned empty/rejected (corrupt parse OR a guard mismatch —
    # goal_hash/repo_id/scope_manifest_ref/status), surface it instead of a
    # silent degrade. ZBUILD_PLAN_RESUME=0 is an explicit operator opt-out, not a
    # skip worth reporting, so exclude it.
    if [[ -z "$_resume_text" && "${ZBUILD_PLAN_RESUME:-1}" != "0" ]]; then
        local _resume_leaf
        _resume_leaf="$(plan_context_path "$_resume_repo_id" "$_resume_scope_key" "$_resume_goal_hash")"
        if [[ -f "$_resume_leaf" ]]; then
            emit_event "plan.context.resume_skipped" "plugin=plan" \
                "goal_hash=$_resume_goal_hash" \
                "reason=rejected_or_corrupt"
        fi
    fi
    if [[ -n "$_resume_text" ]]; then
        # Splice the resumed prior-exploration context verbatim. ADR-043: the
        # router redacts the whole assembled prompt by construction, so the
        # out-of-scope paths in this cached reasoning are wrapped in that single
        # pass — no per-splice redaction / C6 bookkeeping is needed anymore.
        prompt+=$'\n## PRIOR EXPLORATION CONTEXT (resumed)\n\n'
        prompt+="$_resume_text"$'\n'

        local _resume_json_path _prior_status _prior_turns
        _resume_json_path="$(plan_context_path "$_resume_repo_id" "$_resume_scope_key" "$_resume_goal_hash")"
        _prior_status="$(jq -r '.status // "unknown"' "$_resume_json_path" 2>/dev/null || echo unknown)"
        _prior_turns="$(jq -r '.num_turns // "unknown"' "$_resume_json_path" 2>/dev/null || echo unknown)"
        emit_event "plan.context.resumed" "plugin=plan" \
            "goal_hash=$_resume_goal_hash" \
            "prior_status=$_prior_status" \
            "prior_num_turns=$_prior_turns"
    fi

    # ADR-050 (#1581): seed from a prior RUN's plan.json — complements the
    # exploration-cache resume above with the actual prior PLAN output. Advisory:
    # reference and refine, don't blindly re-emit. Rides the router's single
    # redaction pass with the rest of the assembled prompt.
    # Gated on ZBUILD_RESTORED_ARTIFACTS_DIR so this fires ONLY on a genuine
    # cross-run restore — plan is a leaf, so it must never pick up stale/leaked
    # cycle-feedback env or its OWN same-run local plan.json (#842 leaf contract).
    local _prior_plan_json=""
    if [[ -n "${ZBUILD_RESTORED_ARTIFACTS_DIR:-}" ]]; then
        _prior_plan_json="$(_read_prior_output "plan.json" 2>/dev/null || true)"
        [[ -n "$_prior_plan_json" ]] && \
            _prior_plan_json="$(printf '%s' "$_prior_plan_json" | _zbuild_sanitize_for_llm)"
    fi
    if [[ -n "${_prior_plan_json//[[:space:]]/}" ]]; then
        prompt+=$'\n## PRIOR PLAN (a previous attempt on this issue — reference & refine; verify against the CURRENT scope)\n\n'
        prompt+="$_prior_plan_json"$'\n'
    fi

    # ADR-032 (#855): the operator override is spliced in AFTER the contract
    # (_plan_instructions) so it follows the shipped charter. ADR-043: it rides
    # the router's single redaction pass over the assembled prompt.
    local _plan_ov; _plan_ov="$(load_prompt_override "plan")"
    if [[ -n "$_plan_ov" ]]; then
        prompt+=$'\n\n'"$ZBUILD_PROMPT_OVERRIDE_DELIMITER"$'\n\n'
        prompt+="$_plan_ov"$'\n'
    fi

    # ─── Route to LLM (T2, matching manifest config.tier_default) ───────────
    # ADR-018 (#476): Pattern 1 stages with tools MUST use JSON envelope mode.
    # Headless text mode streams every turn (reasoning + tools + final) as
    # concatenated text; only .result from the JSON envelope is the
    # final assistant message. Without this, reasoning turns leak as a prose
    # preamble and break the strict-JSON parser below.
    #
    # Save/restore so a caller that set the flag externally is not clobbered.
    local tier; tier="$(resolve_tier plan "$_PLAN_DIR")" || return 1
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # ADR-018 (#483): tag the router's capture so plan's own banner renders
    # the plan.json output via render_plan_md (mirror #476 save/restore).
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_ARTIFACT_ID=plan
    # Carrier var for the INPUT banner persona line; consumed by
    # _stage_io_stdout_begin inside route_to_model. Exported here (not at framing
    # time) so it shares the artifact/json save/restore window and never leaks
    # past the resolve_tier bail-out above.
    local _prev_persona_env="${ZBUILD_STAGE_IO_PERSONA-__UNSET__}"
    if [[ "$_persona_applied" -eq 1 ]]; then
        export ZBUILD_STAGE_IO_PERSONA=product-owner
    else
        export ZBUILD_STAGE_IO_PERSONA=product-owner:fallback
    fi
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
    if [[ "$_prev_persona_env" == "__UNSET__" ]]; then
        unset ZBUILD_STAGE_IO_PERSONA
    else
        export ZBUILD_STAGE_IO_PERSONA="$_prev_persona_env"
    fi

    # ─── Parse: strip fences, validate JSON with .steps array ───────────────
    local plan_json=""
    # #1052: set when a plan was salvaged from a max_turns envelope; the
    # recovery branch already persisted plan-context status=complete, so the
    # success-persist block below must not re-emit plan.context.persisted.
    local _plan_recovered=0
    # #476: distinguish empty-envelope from schema-failure so a future
    # regression (e.g. envelope mode silently disabled) emits a different
    # `reason=` and is grep-detectable.
    local schema_failed=0
    if [[ $router_rc -eq 0 && -n "$raw_response" ]]; then
        # ADR-028 v1.2 (#944): route the rc=0 parse through the shared framework
        # _llm_envelope_parse --schema-gate _plan_envelope_schema_ok. LAST-wins
        # selects the final balanced object; when that object fails the plan
        # schema gate, _llm_recover_envelope_json fires and restores the real
        # envelope from a brace-bearing postamble (supersedes the #478 bare
        # extract_first_json_object). The STRICT validator below stays
        # AUTHORITATIVE for rc=0 acceptance — it additionally requires files[]
        # be strings — so a well-formed-but-invalid response (or a recovered one
        # that still fails it) remains a schema_violation, never resurrected.
        local stripped _plan_prose
        _llm_envelope_parse --schema-gate _plan_envelope_schema_ok \
            "$raw_response" stripped _plan_prose
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
        # #1727: FALL THROUGH to the recovery block below instead of returning 1
        # here. This `return 1` sat ABOVE the #1052 recovery/state-save path, so
        # for exactly the rcs that path exists to serve — 124 (wall-clock
        # timeout) and 137 (OOM kill) — it was unreachable, and a single timeout
        # aborted the whole run with nothing persisted.
        #
        # Observed on runs 20260817184959-54622 / 20260817192215-57314 (#1832):
        # plan killed at 300s mid-tool-use, `reason=router_fatal router_rc=124`,
        # then `pipeline.abort`. route.sh now retries rc=124 once with an
        # escalated timeout and the checkpoint re-injected (#1879); this makes
        # the outcome AFTER that retry recoverable rather than terminal.
        #
        # Not silently downgraded: the diagnostic still fires, and the block
        # below decides the real outcome — a recovered plan (success), a
        # budget-exhaustion signal (rc=10 scope_too_large), or the existing
        # claude_cli_failed path (rc=1). What changes is that the decision is now
        # MADE rather than pre-empted.
        # `recovery_attempted`, NOT `recoverable`: this fires BEFORE recovery
        # runs, so it cannot claim the outcome. Pairing an optimistic
        # `recoverable=1` with a later plugin.run.error would read as a
        # contradiction in the event log. The outcome is carried by the events
        # that follow — plan.envelope.recovered on success, plan.scope_too_large
        # on a budget exhaustion, plugin.run.error otherwise.
        warn "_plan_run_inner: router rc=$router_rc — trying recovery before failing"
        emit_event "plugin.run.router_failed" "plugin=plan" \
            "reason=router_failed" "router_rc=$router_rc" "recovery_attempted=1" \
            2>/dev/null || true
    fi

    # ─── Recovery + scope_too_large (Pillars C/D, #1052) ────────────────────
    # We have no plan from the happy path. Before failing, mirror impact's
    # resilience: (1) try to RECOVER a complete plan an exhausted model may
    # still have emitted (from raw_response AND the router's max_turns sidecar
    # .result); (2) if the failure is specifically error_max_turns/timeout/oom,
    # turn it into a TERMINAL scope_too_large signal (rc=10) instead of an empty
    # plugin.run.error; (3) otherwise keep the existing claude_cli_failed path.
    if [[ -z "$plan_json" ]]; then
        # (a) Envelope recovery — ONLY on a router FAILURE (rc != 0), i.e. the
        # budget-exhaustion / crash path. A model that hit max_turns may still
        # have emitted a valid final plan; try the captured response first, then
        # the router's diagnostic sidecar .result (route.sh persists the failed
        # envelope there; route_to_model returned empty on the non-zero exit).
        # We deliberately do NOT recover on an rc=0 schema failure: the
        # happy-path validator above is STRICTER than _plan_envelope_schema_ok
        # (it also requires files[] be strings), so a well-formed-but-invalid
        # rc=0 response must stay a schema_violation, not be resurrected here.
        local _recovered="" _sidecar_blob=""
        if [[ "$router_rc" -ne 0 ]]; then
            if [[ -n "$raw_response" ]]; then
                _recovered="$(_plan_recover_envelope_json "$raw_response" 2>/dev/null || true)"
            fi
            _sidecar_blob="$(plan_context_recover_sidecar_reasoning "${ZBUILD_CURRENT_STAGE:-plan}" "$artifact_dir" 2>/dev/null || true)"
            if [[ -z "$_recovered" && -n "$_sidecar_blob" ]]; then
                _recovered="$(_plan_recover_envelope_json "$_sidecar_blob" 2>/dev/null || true)"
            fi
        fi
        if [[ -n "$_recovered" ]]; then
            # A genuine, schema-valid plan surfaced — treat as success. plan.json
            # is written by the shared "Write plan.json" path below (fall-through).
            plan_json="$_recovered"
            _plan_recovered=1
            emit_event "plan.envelope.recovered" "plugin=plan" \
                "artifact=plan.json" "recovered_bytes=${#_recovered}"
            # Persist context status=complete + mirror into the per-run artifacts.
            # Only emit plan.context.persisted when the write actually succeeded
            # (its atomic mv rc) — a failed write must not report a false-positive.
            local _rec_ctx_json _rec_ctx_rc=0
            _rec_ctx_json="$(plan_context_write \
                "$_resume_goal_hash" "$_resume_scope_key" "complete" "" "" "$_resume_scope_ref")" || _rec_ctx_rc=$?
            if [[ "$_rec_ctx_rc" -eq 0 ]]; then
                printf '%s\n' "$_rec_ctx_json" > "$artifact_dir/plan-context.json" 2>/dev/null || true
                local _rec_md_path
                _rec_md_path="$(plan_context_md_path "$_resume_repo_id" "$_resume_scope_key" "$_resume_goal_hash")"
                [[ -f "$_rec_md_path" ]] && cp "$_rec_md_path" "$artifact_dir/plan-context.md" 2>/dev/null || true
                emit_event "plan.context.persisted" "plugin=plan" \
                    "goal_hash=$_resume_goal_hash" "status=complete" "recovered=1"
            fi
            # Fall through to the normal post-validate / run.complete path below.
        else
            # (b) No recoverable plan. The failure becomes the terminal
            # scope_too_large abort iff the model exhausted its turn budget
            # (sidecar subtype=error_max_turns). Anything else stays the existing
            # claude_cli_failed / plugin.run.error path.
            local _stl_subtype=""
            # Resolve the sidecar dir from the SAME expression route.sh writes it
            # to, so a caller that set ZBUILD_ARTIFACT_DIR differently from the
            # plugin's local $artifact_dir still finds the max_turns envelope.
            # Fall back to $artifact_dir (existing behavior) when both env unset.
            local _stl_sidecar_base
            if [[ -n "${ZBUILD_ARTIFACT_DIR:-}" ]]; then
                _stl_sidecar_base="$ZBUILD_ARTIFACT_DIR"
            elif [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
                _stl_sidecar_base="$ZBUILD_STATE_DIR/artifacts"
            else
                _stl_sidecar_base="$artifact_dir"
            fi
            local _stl_sidecar="$_stl_sidecar_base/stage-io/${ZBUILD_CURRENT_STAGE:-plan}-sync-error.raw-claude-output.json"
            if [[ ! -f "$_stl_sidecar" ]]; then
                # Glob-fallback to the newest matching sidecar (mirror the lib).
                local _stl_f _stl_newest=""
                for _stl_f in "$_stl_sidecar_base"/stage-io/"${ZBUILD_CURRENT_STAGE:-plan}"-*error*.raw-claude-output.json; do
                    [[ -e "$_stl_f" ]] || continue
                    if [[ -z "$_stl_newest" || "$_stl_f" -nt "$_stl_newest" ]]; then _stl_newest="$_stl_f"; fi
                done
                _stl_sidecar="$_stl_newest"
            fi
            if [[ -n "$_stl_sidecar" && -f "$_stl_sidecar" ]]; then
                _stl_subtype="$(jq -r '.subtype // ""' "$_stl_sidecar" 2>/dev/null || true)"
            fi
            # The deliberate discriminator (per the DoD): scope_too_large fires
            # SOLELY on subtype=error_max_turns — the model burning its turn
            # budget. A hard router timeout/oom WITHOUT that subtype is genuine
            # CLI failure and correctly stays on the claude_cli_failed/rc=1 path.
            # (A prior router_timeout/oom branch was unreachable: it required the
            # same error_max_turns subtype the if above already matches.)
            local _is_scope_too_large=0
            if [[ "$_stl_subtype" == "error_max_turns" ]]; then
                _is_scope_too_large=1
            fi

            if [[ "$_is_scope_too_large" -eq 1 ]]; then
                # Recover partial reasoning + num_turns.
                #
                # #1879: prefer the MODEL-WRITTEN checkpoint over the sidecar
                # distillation. The sidecar route cannot work: the CLI's
                # error_max_turns envelope carries neither `.result` nor
                # `.tool_uses` (verified against the real #1708 artifact), so
                # plan_context_recover_sidecar_reasoning distils only
                # "num_turns: N" — which is what made #1052's "re-running this
                # issue will resume from it" an empty promise. The checkpoint is
                # what the model actually recorded as it worked.
                local _stl_reasoning _stl_turns _stl_checkpoint=""
                if declare -F _checkpoint_declared_path >/dev/null 2>&1; then
                    local _stl_cp_path
                    _stl_cp_path="$(_checkpoint_declared_path "$_PLAN_DIR/manifest.yaml" \
                        "${ZBUILD_STATE_DIR:-$(dirname "$artifact_dir")}" 2>/dev/null || true)"
                    [[ -n "$_stl_cp_path" && -s "$_stl_cp_path" ]] && _stl_checkpoint="$(cat "$_stl_cp_path" 2>/dev/null || true)"
                fi
                _stl_reasoning="$_stl_checkpoint"
                [[ -z "$_stl_reasoning" ]] && _stl_reasoning="$_sidecar_blob"
                [[ -z "$_stl_reasoning" ]] && _stl_reasoning="$(plan_context_recover_sidecar_reasoning "${ZBUILD_CURRENT_STAGE:-plan}" "$artifact_dir" 2>/dev/null || true)"
                _stl_turns="$(jq -r '.num_turns // ""' "$_stl_sidecar" 2>/dev/null || true)"

                # Persist scope_too_large context (cross-run cache + per-run copy).
                # Only emit plan.context.persisted when the write succeeded (its
                # atomic mv rc); the terminal plan.scope_too_large + rc=10 still
                # fire regardless so the abort signal is never lost.
                local _stl_ctx_json _stl_ctx_rc=0
                _stl_ctx_json="$(plan_context_write \
                    "$_resume_goal_hash" "$_resume_scope_key" "scope_too_large" \
                    "$_stl_turns" "$_stl_reasoning" "$_resume_scope_ref")" || _stl_ctx_rc=$?
                if [[ "$_stl_ctx_rc" -eq 0 ]]; then
                    printf '%s\n' "$_stl_ctx_json" > "$artifact_dir/plan-context.json" 2>/dev/null || true
                    local _stl_md_path
                    _stl_md_path="$(plan_context_md_path "$_resume_repo_id" "$_resume_scope_key" "$_resume_goal_hash")"
                    [[ -f "$_stl_md_path" ]] && cp "$_stl_md_path" "$artifact_dir/plan-context.md" 2>/dev/null || true
                    emit_event "plan.context.persisted" "plugin=plan" \
                        "goal_hash=$_resume_goal_hash" "status=scope_too_large"
                fi
                emit_event "plan.scope_too_large" "plugin=plan" \
                    "goal_hash=$_resume_goal_hash" \
                    "num_turns=${_stl_turns:-unknown}" \
                    "candidate_split=true"

                # Terminal message (stderr) — mirror llm-agent.sh:349 shape.
                printf '✗ Pipeline aborted: plan stage exhausted its turn budget (turns=%s) without a complete plan. The issue is likely too large — SPLIT IT into smaller sub-issues. Partial exploration saved to %s; re-running this issue will resume from it.\n' \
                    "${_stl_turns:-unknown}" "$artifact_dir/plan-context.md" >&2

                # D9 (#1024) guard: scope_too_large is a SUCCESSFUL model run that
                # hit a budget, NOT CLI unavailability. The plan plugin never
                # calls _zbuild_record_cli_fail (only review/test_assessment do),
                # so the #1024 counter is untouched here — rc=10 (scope_too_large)
                # and rc=9 (llm_unavailable) stay semantically distinct. Reset
                # defensively in case a future wrapper records it for this path.
                _zbuild_reset_cli_fail 2>/dev/null || true

                # No fake plan.json. Terminal abort code (Wave A: rc=10, NOT rc=8;
                # rc=8 is blocking_member_failure per ADR-013).
                return 10
            fi

            # (c) Genuine non-max_turns failure → existing claude_cli_failed path.
            local _reason="invalid_plan_response"
            [[ $router_rc -eq 0 && -z "$raw_response" ]] && _reason="empty_result_envelope"
            [[ $schema_failed -eq 1 ]] && _reason="schema_violation"
            error "_plan_run_inner: no valid plan.json produced (reason=$_reason)"
            emit_event "plugin.run.error" "plugin=plan" "reason=$_reason"
            return 1
        fi
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
    if ! _plan_validate_dod_discipline "$plan_json" "$goal_content"; then
        dod_discipline_pass=0
    fi

    # ─── Persist plan-context on success (Pillar A, #1052) ──────────────────
    # plan.json stays the PRIMARY verdict-bearing artifact (ADR-020); the
    # plan-context cache is SECONDARY (durable cross-run resume hint). On a
    # normal valid plan, write status=complete to the namespaced cache and
    # mirror it into the per-run artifacts dir. Skip when the plan was already
    # persisted by the recovery branch above.
    if [[ "$_plan_recovered" -ne 1 ]]; then
        # Only emit plan.context.persisted when the write succeeded (its atomic
        # mv rc); a failed cache write must not report a false-positive persist.
        local _ok_ctx_json _ok_ctx_rc=0
        _ok_ctx_json="$(plan_context_write \
            "$_resume_goal_hash" "$_resume_scope_key" "complete" "" "" "$_resume_scope_ref")" || _ok_ctx_rc=$?
        if [[ "$_ok_ctx_rc" -eq 0 ]]; then
            printf '%s\n' "$_ok_ctx_json" > "$artifact_dir/plan-context.json" 2>/dev/null || true
            local _ok_md_path
            _ok_md_path="$(plan_context_md_path "$_resume_repo_id" "$_resume_scope_key" "$_resume_goal_hash")"
            [[ -f "$_ok_md_path" ]] && cp "$_ok_md_path" "$artifact_dir/plan-context.md" 2>/dev/null || true
            emit_event "plan.context.persisted" "plugin=plan" \
                "goal_hash=$_resume_goal_hash" "status=complete"
        fi
    fi

    emit_event "plugin.run.complete" "stage=plan" \
        "plugin=plan" \
        "step_count=$step_count" \
        "scope_violations=$scope_violations" \
        "dod_discipline_pass=$dod_discipline_pass" \
        "artifact=plan.json"

    # ─── Opportunistic GC (Pillar F, #1052) ─────────────────────────────────
    # Self-trim the cross-run cache so it never grows unbounded; gated by
    # ZBUILD_PLAN_CONTEXT_GC (default 1) and quota-bounded inside the helper.
    plan_context_gc 2>/dev/null || true

    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
plan_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=plan"
    return 0
}
