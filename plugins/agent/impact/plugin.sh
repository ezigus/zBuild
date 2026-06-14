#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/impact — Impact Analyzer Stage (#842)                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Member of design_impact_cycle. Reads design.md's ```scope block (the
# exhaustive enumeration produced by the design stage) and adversarially
# finds post-design CONSEQUENCES: files the change touches but design missed.
# Emits impact.json { verdict: complete | incomplete, ... } and
# impact_feedback.md wired back into design.prior_impact_feedback.
# plan.json is retained as secondary input for the deterministic prefilter.

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
# ADR-028: shared LLM-agent stage framework (PR 5/5 — impact migration +
# consolidates accreted bloat from PRs #767/#771/#774/#783).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_IMPACT_ROOT/scripts/lib/llm-agent.sh"
# #781: deterministic scope prefilter (CLAUDE.md test-scope rule).
# shellcheck source=../../../scripts/lib/impact-prefilter.sh
source "$_IMPACT_ROOT/scripts/lib/impact-prefilter.sh"
# #782: router rc → verdict/reason mapping (ADR-021 error class for timeouts).
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_IMPACT_ROOT/scripts/lib/router-rc-classify.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_IMPACT_ROOT/scripts/lib/prompt-overrides.sh"

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
        "$artifacts_dir/design.md" \
        "$artifacts_dir/plan.json" \
        "$artifacts_dir/impact.json" \
        "$artifacts_dir"
}

# Extract the ```scope block from design.md; returns CSV of file paths on stdout.
_impact_extract_scope_from_design() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local in_block=0
    local -a files=()
    while IFS= read -r line; do
        if [[ "$line" == '```scope' ]]; then
            in_block=1; continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then break; fi
        if [[ $in_block -eq 1 && -n "$line" ]]; then files+=("$line"); fi
    done < "$design_md"
    if [[ ${#files[@]} -gt 0 ]]; then
        local IFS=','; printf '%s' "${files[*]}"
    fi
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = design.md path (primary scope source)
#   $3 = plan.json path (secondary — for deterministic prefilter)
#   $4 = output impact.json path
#   $5 = artifact_dir (for intermediate files)
_impact_run_inner() {
    local scope_manifest="$1"
    local design_md_path="$2"
    local plan_json_path="$3"
    local output_impact_json="$4"
    local artifact_dir="${5:-$(dirname "$output_impact_json")}"

    if [[ -z "$scope_manifest" || -z "$design_md_path" || -z "$output_impact_json" ]]; then
        error "_impact_run_inner: requires <scope_manifest> <design_md_path> <plan_json_path> <output_impact_json> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    if [[ ! -f "$design_md_path" ]]; then
        error "_impact_run_inner: design.md not found at $design_md_path"
        emit_event "plugin.run.error" "plugin=impact" "reason=missing_design_md"
        return 2
    fi

    # Extract scope from design.md's ```scope block (primary source).
    local scope_csv=""
    scope_csv="$(_impact_extract_scope_from_design "$design_md_path" 2>/dev/null || echo "")"

    # plan.json is secondary — used only by the deterministic prefilter.
    local plan_content=""
    if [[ -f "$plan_json_path" ]]; then
        plan_content="$(cat "$plan_json_path")"
    fi

    # ─── Build prompt ────────────────────────────────────────────────────────
    # ADR-028: canonical OUTPUT CONTRACT from framework. Consolidates the
    # quadruple-redundant "begins with `{`" / FORBIDDEN / INCORRECT-examples
    # / REMINDER triplets that PRs #767/#771/#774/#783 accreted (see plan
    # in docs/adr/ADR-028). impact_feedback_md is a markdown free-text
    # field → ADR-022 v2 escape requirement applies.
    local _impact_schema
    _impact_schema="$(cat <<'IMPACT_SCHEMA'
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
    "impact_feedback_md": "<markdown report fed back to the design agent on the next cycle iter>"
  }
IMPACT_SCHEMA
)"
    local _output_contract_block
    _output_contract_block="$(_llm_output_contract \
        --stage impact \
        --verdicts "complete,incomplete" \
        --schema-json "$_impact_schema" \
        --markdown-fields "impact_feedback_md")"

    # Build design.md scope summary for the prompt.
    local _scope_list=""
    if [[ -n "$scope_csv" ]]; then
        _scope_list="$(printf '%s' "$scope_csv" | tr ',' '\n' | sed 's/^/- /')"
    fi

    local _impact_instructions
    _impact_instructions="$(cat <<'IMPACT_PROMPT'
You are an Impact Analyzer agent. The design stage has already produced an
EXHAUSTIVE scope block enumerating every file the change touches. Your job
is adversarial consequence-finding: identify files that are MISSING from
the design scope block — files the change invalidates, references, validates,
documents, or assumes something about — that the design agent overlooked.

Tool use:
- You MAY use the Read tool to inspect files in the design scope.
- You MAY use the Grep tool to search the repo for symbols and references.
- Do NOT call Edit, Write, or Bash. This stage is read-only.

Rules:
- For each file in the DESIGN SCOPE BLOCK, identify symbols, constants,
  counts, stage IDs, or ORDERING/POSITION/SEQUENCE assertions (e.g. a test
  asserting an array index like _TPL_STAGES[2], or "X comes before Y")
  defined or changed there. A change that REORDERS stages invalidates every
  test that pins a stage by its position/index, even if the stage set is
  unchanged.
- Grep the repo for those symbols. Find files NOT already listed in the
  DESIGN SCOPE BLOCK that reference or pin them.
- For each gap, add an entry to missing[] with a step_id (use the closest
  logical grouping), the files to add, and a one-line reason.
- If no gaps found, return verdict="complete" with missing=[].
- The impact_feedback_md is what the design agent reads on iter N+1 when
  you returned incomplete. Make it actionable: name the missing files,
  cite the symbol or reference that linked them.

IMPACT_PROMPT
)"
    _impact_instructions="$_output_contract_block

$_impact_instructions"

    # #781: deterministic prefilter. Runs CLAUDE.md's "Test scope discovery"
    # rule (grep tests/ for old numeric shape values + scan tests/golden/**)
    # using plan.json for shape inference. Produces a JSON array of candidate
    # gaps spliced BEFORE the DESIGN SCOPE BLOCK. shape-change-golden entries
    # are CLAUDE.md mandates (post-LLM bash merge enforces them); shape-change-
    # numeric entries are advisory (LLM may drop with a reason).
    local _impact_repo_root="${ZBUILD_REPO_ROOT:-${_IMPACT_ROOT:-$(pwd)}}"
    local _prefilter_candidates="[]"
    _prefilter_candidates="$(_impact_scope_prefilter "$plan_content" "$_impact_repo_root" 2>/dev/null || printf '[]')"
    local _candidate_gaps_section=""
    if [[ "$_prefilter_candidates" != "[]" ]] && [[ -n "$_prefilter_candidates" ]]; then
        # No trailing newlines in this substitution body — $(...) strips them;
        # the printf -v below adds the separators explicitly.
        _candidate_gaps_section="$(printf 'CANDIDATE GAPS (deterministic prefilter — you MUST VALIDATE each and KEEP all entries with source=shape-change-golden; you MAY drop false-positive shape-change-numeric entries with a one-line reason):\n%s' "$_prefilter_candidates")"
    fi

    # Assemble: instructions → CANDIDATE GAPS (if any) → DESIGN SCOPE BLOCK.
    local prompt
    if [[ -n "$_candidate_gaps_section" ]]; then
        printf -v prompt '%s\n\n%s\n\nDESIGN SCOPE BLOCK:\n%s\n' \
            "$_impact_instructions" "$_candidate_gaps_section" "$_scope_list"
    else
        printf -v prompt '%s\n\nDESIGN SCOPE BLOCK:\n%s\n' \
            "$_impact_instructions" "$_scope_list"
    fi

    local prompt_file="$artifact_dir/impact-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"

    # ADR-032 (#855): per-repo override appended AFTER the contract, BEFORE
    # redaction (so it is redaction-covered and cannot weaken the charter).
    append_prompt_override "$prompt_file" "impact"

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
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # #768: tag stage-io capture so render_artifact dispatches to
    # render_impact_md (Impact: verdict=..., missing=...) instead of dumping
    # the raw JSON envelope. Mirrors the plan/review/test_assessment pattern.
    export ZBUILD_ROUTER_ARTIFACT_ID=impact

    set +e
    raw_response="$(route_to_model "$tier" "$redacted_prompt")"
    router_rc=$?
    set -e

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

    if [[ $router_rc -ne 0 ]]; then
        # #782: ADR-021 error class for infra timeouts (rc=124 = gtimeout).
        # Write impact.json with verdict=error so the cycle's blocked-
        # predicate can distinguish "router timed out" from "model wrong".
        # Fail-soft return so the cycle can record the error verdict and
        # decide on its own termination (rather than blowing up the runner).
        local _rc_verdict _rc_reason
        _router_rc_classify "$router_rc" _rc_verdict _rc_reason
        error "_impact_run_inner: router rc=$router_rc → verdict=$_rc_verdict reason=$_rc_reason"
        emit_event "plugin.run.error" "plugin=impact" "reason=$_rc_reason" "router_rc=$router_rc"
        if [[ "$_rc_verdict" == "error" ]]; then
            printf '{"schema_version":1,"verdict":"error","reason":"%s","missing":[],"impact_feedback_md":""}\n' \
                "$_rc_reason" > "$output_impact_json"
            # Emit verdict event for cycle predicate consumption.
            emit_event "impact.verdict.error" "plugin=impact" "artifact=impact.json" "reason=$_rc_reason"
            return 0
        fi
        return 1
    fi

    # #767: Extract JSON AND surrounding prose using the sibling helper so
    # any contract-violating prose preamble/postamble is preserved as a
    # sidecar artifact (impact-stray-prose.txt) instead of silently discarded.
    # The stronger prompt above tells haiku to emit clean JSON; this captures
    # forensics when it still doesn't.
    local impact_json="" impact_prose=""
    if [[ -n "$raw_response" ]]; then
        local _esp_out
        _esp_out="$(printf '%s' "$raw_response" | extract_json_and_surrounding_prose 2>/dev/null || true)"
        impact_prose="$(awk '/^__PROSE__$/{p=1;next} /^__JSON__$/{p=0;next} p' <<<"$_esp_out")"
        impact_json="$(awk '/^__JSON__$/{j=1;next} j' <<<"$_esp_out")"
    fi

    # #767: persist captured prose to a sidecar AND emit a contract-violation
    # event so operators can spot model drift in events.jsonl. Best-effort
    # writes; failure does not block verdict extraction.
    if [[ -n "$impact_prose" ]]; then
        local _prose_sidecar="$artifact_dir/impact-stray-prose.txt"
        printf '%s\n' "$impact_prose" > "$_prose_sidecar" 2>/dev/null || true
        emit_event "impact.contract.violation" \
            "plugin=impact" \
            "prose_length=${#impact_prose}" \
            "sidecar=$_prose_sidecar" 2>/dev/null || true
    fi

    if [[ -z "$impact_json" ]]; then
        error "_impact_run_inner: empty or malformed response from LLM"
        emit_event "plugin.run.error" "plugin=impact" "reason=empty_response"
        return 1
    fi

    # Copilot #747: strict schema validation — fail with plugin.run.error
    # rather than silently degrading. impact.json drives cycle convergence,
    # so a malformed response that grants verdict=incomplete via the soft
    # default could let max_iterations=3 + on_max=continue ship a
    # half-validated plan downstream. Mirrors test_assessment / plan
    # behavior (jq -e on a structural assertion, then error event).
    if ! printf '%s' "$impact_json" | jq -e '
        type == "object"
        and (.schema_version == 1)
        and (.verdict | type == "string" and (. == "complete" or . == "incomplete" or . == "error"))
        and (.missing | type == "array")
        and (.impact_feedback_md | type == "string")
    ' >/dev/null 2>&1; then
        error "_impact_run_inner: impact.json schema violation (requires schema_version=1, verdict ∈ {complete,incomplete}, missing[], impact_feedback_md string)"
        emit_event "plugin.run.error" "plugin=impact" "reason=schema_violation"
        return 1
    fi

    # #781/#881: enforce the shape-change hard floor. shape-change-golden
    # (event-sequence snapshots) AND shape-change-order (`_TPL_STAGES[N]` index
    # assertions) are CLAUDE.md mandates, not heuristics — if the LLM dropped
    # them, bash-merge back into missing[] using jq NATIVE SET DIFFERENCE
    # (review: CSV substring containment was vulnerable to path collisions
    # like "parity/.golden" vs "special/parity/.golden"). shape-change-numeric
    # candidates are advisory (LLM may drop as false positives). Failures
    # inside this merge are HARD ERRORS — silently keeping verdict=complete
    # would defeat the exact regression #781 fixes.
    if [[ "$_prefilter_candidates" != "[]" ]] && [[ -n "$_prefilter_candidates" ]]; then
        local _missing_golden_json
        if ! _missing_golden_json="$(jq -nc \
                --argjson candidates "$_prefilter_candidates" \
                --argjson llm_missing "$(printf '%s' "$impact_json" | jq -c '.missing // []')" '
            ($candidates | map(select(.source == "shape-change-golden" or .source == "shape-change-order") | .files_to_add[])) as $forced |
            ($llm_missing | map(.files_to_add // [] | .[])) as $present |
            ($forced - $present | unique)
        ' 2>/dev/null)"; then
            error "_impact_run_inner: prefilter floor merge (jq) failed — refusing to ship LLM verdict unchanged (#781)"
            emit_event "plugin.run.error" "plugin=impact" "reason=prefilter_merge_failed"
            return 1
        fi
        if [[ "$_missing_golden_json" != "[]" ]] && [[ -n "$_missing_golden_json" ]]; then
            if ! impact_json="$(printf '%s' "$impact_json" | jq -c \
                    --argjson files "$_missing_golden_json" '
                .verdict = "incomplete" |
                .missing += [{
                    step_id: "prefilter",
                    files_to_add: $files,
                    reason: ("deterministic prefilter floor (#781/#881): shape-change detected; " +
                             "event-sequence goldens + stage-order (_TPL_STAGES[N]) tests required regardless of LLM judgment")
                }]
            ' 2>/dev/null)"; then
                error "_impact_run_inner: prefilter floor injection (jq) failed — refusing to ship (#781)"
                emit_event "plugin.run.error" "plugin=impact" "reason=prefilter_inject_failed"
                return 1
            fi
        fi
    fi

    local verdict
    verdict="$(printf '%s' "$impact_json" | jq -r '.verdict' 2>/dev/null || echo incomplete)"

    # Write impact.json
    printf '%s\n' "$impact_json" | atomic_write "$output_impact_json"

    # Extract and write impact_feedback.md sibling for cycle feedback wiring.
    # Copilot #747: atomic_write preserves the rename-into-place contract so
    # a mid-write interrupt doesn't leave a partial feedback file that the
    # cycle orchestrator could read on the next iter.
    local feedback_md
    feedback_md="$(printf '%s' "$impact_json" | jq -r '.impact_feedback_md // ""' 2>/dev/null || true)"
    printf '%s\n' "$feedback_md" | atomic_write "$artifact_dir/impact_feedback.md"

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
