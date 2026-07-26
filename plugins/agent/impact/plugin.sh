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
# ADR-050 (#1581): unified prior-work seam — seed from a prior run's impact.json.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_IMPACT_ROOT/scripts/lib/prior-output-reader.sh"
# #721 sanitizer — strip stage-io/ANSI from prior content before the LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_IMPACT_ROOT/scripts/lib/test-output-sanitize.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_IMPACT_ROOT/scripts/lib/prompt-overrides.sh"
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_IMPACT_ROOT/core/plugin-registry/registry.sh"

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

    # Persona seam (#1393 pattern): open the prompt with the architect persona's
    # framing when its manifest is present; falls back byte-identically when absent.
    local _task_intro="The design stage has already produced an EXHAUSTIVE scope block enumerating every file the change touches. Your job is adversarial consequence-finding: identify files that are MISSING from the design scope block — files the change invalidates, references, validates, documents, or assumes something about — that the design agent overlooked."
    local _persona_fallback="$_task_intro"
    local _persona_applied=0
    local _framing
    _framing="$(persona_stage_framing architect "$_task_intro" "$_IMPACT_ROOT/plugins" 2>/dev/null)" \
        && _persona_applied=1 \
        || { warn "impact: persona_stage_framing failed — using fallback framing"; _framing="$_persona_fallback"; }
    # Guard: rc=0 but empty output (e.g. perspective key absent in manifest).
    [[ -n "$_framing" ]] || { _framing="$_persona_fallback"; _persona_applied=0; }

    local _impact_body
    _impact_body="$(cat <<'IMPACT_PROMPT'

Tool use:
- You MAY use the Read tool to inspect files in the design scope.
- You MAY use the Grep tool to search the repo for symbols and references.
- Do NOT call Edit, Write, or Bash. This stage is read-only.

EXISTENCE VERIFICATION (mandatory — do not skip):
- Before adding any path to missing[].files_to_add, confirm the file exists
  in the repository using the Read or Grep tool.
- NEVER list a path you cannot verify is present in the repo. Non-existent
  paths MUST NOT be flagged as scope gaps.

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
- RELEVANCE: a file is a scope gap ONLY if it references a symbol, constant,
  count, stage id, ORDER/position, or path that THIS change adds, removes,
  renames, reorders, or re-counts. Name that specific reference in the reason.
- ADJACENCY IS NOT A GAP: a file is NOT missing merely because it lives in the
  same directory, imports a shared lib, or sits in the changed file's reference
  closure. Do NOT chase transitive references. Return verdict="complete" once
  every file that pins a CHANGED symbol/count/order/path is already in the
  DESIGN SCOPE BLOCK, even if topically-related files remain unlisted.
- If no gaps found, return verdict="complete" with missing=[].
- The impact_feedback_md is what the design agent reads on iter N+1 when
  you returned incomplete. Make it actionable: name the missing files,
  cite the symbol or reference that linked them.

BUDGET DISCIPLINE (read this — you have a BOUNDED tool-call budget):
- You have a LIMITED number of tool calls. Do NOT exhaust them grepping
  exhaustively — a partial-but-emitted verdict beats running out of turns
  and returning nothing.
- Triage: target the HIGHEST-RISK gaps first (renamed/removed symbols, shape
  counts, order assertions, goldens). A handful of focused greps, not a sweep.
- STOP exploring and EMIT your JSON verdict well before your budget runs out.
  If unsure but out of budget, return verdict="incomplete" with the gaps you
  DID find — never keep searching past the point of being able to answer.
- After emitting the closing `}`, output NOTHING — no trailing commentary,
  no ` ``` ` or ` ```json ` fence, no summary sentence.

IMPACT_PROMPT
)"
    local _impact_instructions="${_framing}
${_impact_body}"
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

    # ADR-050 (#1581): seed from a prior RUN's impact.json. Advisory — reference the
    # prior gap analysis, but re-derive against the CURRENT design/tests (the
    # deterministic prefilter above stays authoritative for goldens). Gated on
    # ZBUILD_RESTORED_ARTIFACTS_DIR so it fires ONLY on a genuine cross-run restore
    # (never stale cycle env or impact's OWN same-run local impact.json).
    local _prior_impact=""
    if [[ -n "${ZBUILD_RESTORED_ARTIFACTS_DIR:-}" ]]; then
        _prior_impact="$(_read_prior_output "impact.json" 2>/dev/null || true)"
        [[ -n "$_prior_impact" ]] && \
            _prior_impact="$(printf '%s' "$_prior_impact" | _zbuild_sanitize_for_llm)"
    fi
    if [[ -n "${_prior_impact//[[:space:]]/}" ]]; then
        prompt+=$'\n## PRIOR IMPACT (a previous attempt on this issue — reference & refine; re-validate against the CURRENT design)\n'
        prompt+="$_prior_impact"$'\n'
    fi

    local prompt_file="$artifact_dir/impact-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"

    # ADR-032 (#855): per-repo override appended AFTER the contract (so the
    # operator overlay can never precede or weaken the shipped charter). ADR-043:
    # redaction is owned by the router — it covers this override too.
    append_prompt_override "$prompt_file" "impact"

    # ─── Assemble the raw prompt (ADR-043: route_to_model redacts it). ──────
    local redacted_prompt
    redacted_prompt="$(cat "$prompt_file")"

    # ─── Route to LLM (T2 default per manifest config.tier_default, #960/#1230) ─
    # The fallback MUST match manifest tier_default (T2). On T1 (haiku) impact's
    # ~45 tool-turns overran the then-180s router timeout (rc=124); #1242 later
    # right-sized that wall-clock budget to 600s (see the templates). The
    # Tier from the single source of truth: impact's own manifest
    # config.tier_default (T2), via resolve_tier (#1231). ZBUILD_IMPACT_TIER
    # still overrides. No hardcoded literal — that is what drifted in #960/#1230.
    local tier; tier="$(resolve_tier impact "$_IMPACT_DIR")" || return 1
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    # #768: tag stage-io capture so render_artifact dispatches to
    # render_impact_md (Impact: verdict=..., missing=...) instead of dumping
    # the raw JSON envelope. Mirrors the plan/review/test_assessment pattern.
    export ZBUILD_ROUTER_ARTIFACT_ID=impact
    local _prev_persona_env="${ZBUILD_STAGE_IO_PERSONA-__UNSET__}"
    if [[ "$_persona_applied" -eq 1 ]]; then
        export ZBUILD_STAGE_IO_PERSONA=architect
    else
        export ZBUILD_STAGE_IO_PERSONA=architect:fallback
    fi

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
    if [[ "$_prev_persona_env" == "__UNSET__" ]]; then
        unset ZBUILD_STAGE_IO_PERSONA
    else
        export ZBUILD_STAGE_IO_PERSONA="$_prev_persona_env"
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
        # #937: a TIMEOUT (rc=124, reason=router_timeout) is RECOVERABLE — fall
        # through to the #892 best-effort verdict=incomplete path (re-iterate)
        # rather than writing an empty verdict=error that wastes the iteration.
        # The plugin.run.error event above already preserves reason=router_timeout
        # for postmortems. Genuine infra errors (OOM rc=137, claude crash) keep
        # verdict=error so the cycle's blocked-predicate can flag them.
        if [[ "$_rc_verdict" == "error" && "$_rc_reason" != "router_timeout" ]]; then
            printf '{"schema_version":1,"verdict":"error","reason":"%s","missing":[],"impact_feedback_md":""}\n' \
                "$_rc_reason" > "$output_impact_json"
            # Emit verdict event for cycle predicate consumption.
            emit_event "impact.verdict.error" "plugin=impact" "artifact=impact.json" "reason=$_rc_reason"
            return 0
        fi
        # #892 + #937: best-effort verdict on a RECOVERABLE router failure —
        # rc=1 (max_turns) OR rc=124 (timeout). Was a fail-CLOSED return 1 with
        # NO impact.json, which gave the cycle a MISSING artifact and an empty
        # iteration. Instead write verdict=incomplete (so the cycle RE-ITERATES,
        # another shot) with a best-effort note. The reason field carries the
        # classified reason ($_rc_reason — e.g. router_timeout) so the artifact,
        # not just the event, records what failed.
        local _be_md
        _be_md="$(printf 'Impact analysis did not complete (router rc=%s, reason=%s). The design scope block was NOT adversarially verified this iteration; treat it as unconfirmed. Re-run impact with a tighter, verdict-first pass.' \
            "$router_rc" "$_rc_reason")"
        jq -nc --arg md "$_be_md" --arg reason "$_rc_reason" \
            '{schema_version:1, verdict:"incomplete", reason:$reason, missing:[], impact_feedback_md:$md}' \
            > "$output_impact_json" 2>/dev/null \
            || printf '{"schema_version":1,"verdict":"incomplete","reason":"%s","missing":[],"impact_feedback_md":"impact did not complete (router rc=%s)"}\n' "$_rc_reason" "$router_rc" > "$output_impact_json"
        emit_event "impact.verdict.incomplete" "plugin=impact" "artifact=impact.json" "reason=router_failed_best_effort"
        return 0
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
    if ! _impact_envelope_schema_ok "$impact_json"; then
        # #908: the shared parser is LAST-wins (#478/ADR-018) and impact emits
        # its envelope FIRST. A brace-bearing postamble (commentary, or an
        # example after a stray ```json fence) makes LAST-wins select the
        # postamble object and fail the gate. Before erroring, attempt
        # schema-aware recovery: re-scan the ORIGINAL raw response for the FIRST
        # top-level object that passes the impact schema gate. The #767 prose
        # sidecar was already written above; the #781/#881 floor, #911 drop, and
        # #892 router-fail handling all run AFTER this on the recovered object.
        local _recovered=""
        _recovered="$(_impact_recover_envelope_json "$raw_response" 2>/dev/null || true)"
        if [[ -n "$_recovered" ]]; then
            impact_json="$_recovered"
            emit_event "impact.envelope.recovered" "plugin=impact" \
                "reason=last_wins_postamble" \
                "prose_length=${#impact_prose}" \
                "recovered_bytes=${#_recovered}" "artifact=impact.json"
        else
            error "_impact_run_inner: impact.json schema violation (requires schema_version=1, verdict ∈ {complete,incomplete,error}, missing[], impact_feedback_md string)"
            emit_event "plugin.run.error" "plugin=impact" "reason=schema_violation"
            return 1
        fi
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

    # #911: deterministic hallucination post-filter. Strips missing[].files_to_add
    # paths that do not exist on disk; drops entries that become empty; flips
    # verdict incomplete→complete when missing[] is fully cleared.
    # Runs AFTER prefilter floor merge so forced-existing floor entries are safe.
    _impact_drop_nonexistent_missing "${_impact_repo_root}"

    # #936: over-scope-safe convergence backstop. After ghosts are dropped, if
    # impact only re-flags real-but-irrelevant COLLATERAL adjacents in a TRUE
    # plateau (same non-floor set, past the first verdict iter, non-shape-change,
    # no floor entry), flip verdict->complete so design_impact_cycle converges
    # instead of maxing out. Floor entries, structural paths (core/scripts/
    # plugins), and shape changes all suppress the flip — a real reference gap or
    # an unrecoverable omission is never masked. Only flips verdict, never drops.
    _impact_converge_on_overscope "${_impact_repo_root}" "$artifact_dir" "$plan_content" "$scope_csv"

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
