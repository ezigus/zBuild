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
#   design_stage_run         — derive paths, delegate to _design_stage_run_inner
#   _design_stage_run_inner  — redact → route_to_model_loop → assert scope block
#   design_stage_cleanup     — no-op (the engine brackets the hook, #1705)
#
# legacy-citation: pipeline-stages-intake.sh:1004 (stage_design function)
# legacy-citation: pipeline-stages.sh:38-71 (_extract_scope_from_design helper)

[[ -n "${_ZBUILD_DESIGN_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_DESIGN_DIR="$_ZBUILD_PLUGIN_DIR"
_DESIGN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DESIGN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_DESIGN_ROOT/core/router/route.sh"
# shellcheck source=../../../core/output/stage-io.sh
source "$_DESIGN_ROOT/core/output/stage-io.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_DESIGN_ROOT/scripts/lib/prompt-overrides.sh"
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_DESIGN_ROOT/scripts/lib/router-rc-classify.sh"
# ADR-050 (#1581): unified prior-work seam — read prior design.md from an
# intra-cycle iter OR a prior run's restored/local artifact via one call.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_DESIGN_ROOT/scripts/lib/prior-output-reader.sh"
# Persona resolver + stage/lens composition seam (#1304, #1324).
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_DESIGN_ROOT/core/plugin-registry/registry.sh"
# ADR-059 §6 (#1930): one owner/repo derivation, shared with release-tarball.sh.
# shellcheck source=../../../scripts/lib/identity.sh
source "$_DESIGN_ROOT/scripts/lib/identity.sh"
# #963: read-only grammar lib from _ZBUILD_CONTRACT_LIB_DIR (self-host redirect).
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh"

# _design_write_result <artifact_dir> <verdict> <disposition> <reason>
# Writes design-verdict.json with the v2 result contract (result_contract:2).
# Called on every terminal exit path so the sidecar is always on disk.
_design_write_result() {
    local dir="$1" verdict="$2" disposition="$3" reason="$4"
    mkdir -p "$dir" 2>/dev/null || true
    jq -n --arg v "$verdict" --arg d "$disposition" --arg r "$reason" \
        '{result_contract: 2, verdict: $v, disposition: $d, reason: $r, data: {}}' \
        | atomic_write "$dir/design-verdict.json" 2>/dev/null \
        || warn "_design_write_result: failed to write design-verdict.json (verdict=$verdict)"
}

# _design_budget_guidance <max_turns> — TURN BUDGET block for the prompt (ADR-063 §1).
# Mirrors _plan_budget_guidance from plugins/agent/plan/plugin.sh.
_design_budget_guidance() {
    local budget="${1:-}"
    [[ "$budget" =~ ^[0-9]+$ && "$budget" -gt 0 ]] || { printf ''; return 0; }
    cat <<EOF
TURN BUDGET (read this — you have a BOUNDED tool-call budget):
- You have about ${budget} tool-call turns for BOTH exploration AND writing the design.
- A design from partial exploration with gaps named in prose BEATS exhausting the budget and producing no design at all.
- Explore with TARGETED reads/greps of specific files; avoid whole-repo sweeps that flood your context.
- STOP exploring and WRITE the design well before you run out. If you are running low, emit your best-effort design NOW and name any unfinished sections.
EOF
}

# _design_wallclock_guidance <timeout_s> <elapsed_s> — WALL CLOCK BUDGET block (ADR-063 §1).
# Mirrors _plan_wallclock_guidance from plugins/agent/plan/plugin.sh.
_design_wallclock_guidance() {
    local budget_s="${1:-}" elapsed_s="${2:-}"
    [[ "$budget_s" =~ ^[0-9]+$ && "$budget_s" -gt 0 ]] || { printf ''; return 0; }
    [[ "$elapsed_s" =~ ^[0-9]+$ ]] || elapsed_s=0
    [[ "$elapsed_s" -lt "$budget_s" ]] || { printf ''; return 0; }
    local _stop_at=$(( budget_s * 70 / 100 ))
    cat <<EOF
WALL CLOCK BUDGET (read this — the stage has a hard OS wall-clock timeout):
- This stage has a wall-clock budget of ${budget_s} seconds total; ~${elapsed_s}s have elapsed.
- You cannot read a real-time clock, but estimate elapsed time from your tool-call history.
- Target emitting your best-effort design before ~${_stop_at}s of wall-clock time has elapsed (70% of the ${budget_s}s budget). A partial design with named gaps BEATS a hard SIGTERM that produces no output.
EOF
}

# ─── run ────────────────────────────────────────────────────────────────────
design_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "design_stage_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/design-summary.md}" "design" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 1
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local scope_manifest="$state_dir/scope-manifest.md"
    local plan_json_path="$artifacts_dir/plan.json"

    # ADR-017 §11 / #1826: when the engine resolved inputs via input-resolve.sh it
    # exports ZBUILD_STAGE_INPUTS pointing to a JSON index of name→path pairs.
    # Read scope_manifest and plan from it when present, falling back to the
    # hardcoded path construction so existing test fixtures keep working.
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        local _si_scope _si_plan
        _si_scope="$(jq -r '.inputs.scope_manifest // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
        _si_plan="$(jq -r '.inputs.plan // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
        [[ -n "$_si_scope" ]] && scope_manifest="$_si_scope"
        [[ -n "$_si_plan" ]] && plan_json_path="$_si_plan"
    fi

    _design_stage_run_inner \
        "$scope_manifest" \
        "$plan_json_path" \
        "$artifacts_dir/design.md" \
        "$artifacts_dir"
}


# _design_gate_failed <artifact_dir>  (#1979)
# True when the design-gate's recorded verdict for this run is a failure.
#
# This replaces reading design-gate-feedback.md to decide how to word the PRIOR
# DESIGN instruction. The content itself now reaches the prompt as an
# engine-collected summary (#1976, ADR-055 §9), so the old reader would have
# spliced it a second time — recreating exactly the duplication #1825 removed.
# Keying on the recorded verdict keeps ONE source for the content and makes the
# switch a fact read from state rather than a side effect of a file read.
_design_gate_failed() {
    local artifact_dir="${1:-}"
    [[ -n "$artifact_dir" ]] || return 1
    local state_file; state_file="$(dirname "$artifact_dir")/pipeline-state.json"
    [[ -s "$state_file" ]] || return 1
    local v
    v="$(jq -r '.stage_verdicts["design-gate"] // empty' "$state_file" 2>/dev/null || true)"
    [[ "$v" == "fail" || "$v" == "failed" ]]
}

# design_impact_cycle self-feedback (mirrors #773 lesson): design's own prior
# design.md body to refine rather than re-create.
# ADR-050 (#1581): Tier 1 = intra-cycle (iter≥2 prior_design.txt); Tier 2 = restored
# artifact from a prior run. No state-dir fallback: ./state may hold the CURRENT
# run's design.md, not a prior, and returning it outside a cycle would be wrong.
_design_read_prior_design() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"

    # Tier 1: intra-cycle self-feedback (iter >= 2)
    if [[ -n "$iter" && -n "$fb_dir" && "$iter" =~ ^[0-9]+$ ]] && (( iter >= 2 )); then
        local cycle_f="$fb_dir/design.txt"
        [[ -s "$cycle_f" ]] && { cat "$cycle_f" 2>/dev/null; return 0; }
    fi

    # Tier 2: cross-run restored artifact
    local restored_dir="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    if [[ -n "$restored_dir" ]]; then
        local restored_f="$restored_dir/design.md"
        [[ -s "$restored_f" ]] && { cat "$restored_f" 2>/dev/null; return 0; }
    fi

    return 0
}

# ADR-050 (#1581): best-effort GitHub blob URL for the durable prior design on the
# state branch (zbuild/state/issue-<N>/artifacts/design.md). Empty when the repo
# slug or issue can't be resolved (local run / non-GitHub remote) — the prior
# design CONTENT is injected regardless; this is just a browsable pointer.
_design_state_blob_url() {
    local issue="${ZBUILD_ISSUE:-0}"
    [[ "$issue" =~ ^[0-9]+$ && "$issue" -gt 0 ]] || return 0
    # ADR-059 §6 (#1930): one slug derivation, shared with release-tarball.sh.
    # The local `case` this replaces matched exactly two literal prefixes and
    # returned empty for anything else — so `ssh://git@github.com/o/r` produced
    # a release tarball and NO blob URL. zbuild_repo_slug accepts it.
    local slug
    slug="$(zbuild_repo_slug || true)"
    [[ -n "$slug" ]] || return 0
    printf 'https://github.com/%s/blob/zbuild/state/issue-%s/artifacts/design.md' "$slug" "$issue"
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
        return 1
    fi

    mkdir -p "$artifact_dir"
    local _design_start_s=$SECONDS

    # #1261: the did_not_finish verdict sidecar (mirrors build's #1208 mid-flight
    # verdict). Cleared at the START of every run so a stale timeout verdict from
    # a PRIOR iteration can never leak into a later iteration that produced a real
    # design.md — the cycle would otherwise wrongly read did_not_finish and
    # halt-exhaust on a content-converging run. Written ONLY on a router timeout
    # below. verdict.sh reads it as design's raw verdict for the cycle.
    local design_verdict_sidecar="$artifact_dir/design-verdict.json"
    rm -f "$design_verdict_sidecar"

    if [[ ! -f "$plan_json_path" ]]; then
        error "_design_stage_run_inner: plan.json not found at $plan_json_path"
        _design_write_result "$artifact_dir" "error" "broken" "missing_plan_json"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "no plan.json to design against" \
            "The plan stage produced nothing this stage could read; no design was authored."
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=missing_plan_json"
        return 1
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

    # Persona seam (#1324): open the prompt with the architect persona's framing
    # when its manifest is present; when absent, persona_stage_framing returns 1
    # and we fall back to behavior/task framing without a persona role declaration.
    local _task_intro="Your job is to produce an ADR-style design.md for the task described in the plan below."
    local _persona_applied=0
    local _framing
    local _framing_fallback="Your job is to produce an ADR-style design.md for the task described in the plan below."
    _framing="$(persona_stage_framing architect "$_task_intro" "$_DESIGN_ROOT/plugins" 2>/dev/null)" \
        && _persona_applied=1 \
        || { warn "design: persona_stage_framing failed — using fallback framing"; _framing="$_framing_fallback"; }
    [[ -n "$_framing" ]] || { _framing="$_framing_fallback"; _persona_applied=0; }

    cat > "$prompt_input_file" <<DESIGN_PROMPT
${_framing}

## Plan
$(printf '%s' "$plan_json" | jq -r '.title // "Untitled"' 2>/dev/null)

$(printf '%s' "$plan_json" | jq -r '.description // .goal // ""' 2>/dev/null)

## Seed scope (from plan.files[])
${scope_list}

## Tools (read-only — this stage may NOT modify the working tree)
- You MAY use the Read tool to inspect any file in the repository.
- You MAY use the Grep tool to search the whole repository for symbols,
  constants, references, and hardcoded values.
- You MAY use the Glob tool to discover files by pattern.
- Do NOT call Edit, Write, or Bash for implementation. The ONLY file you
  write is the design.md at the exact path below. Your job is to ENUMERATE
  scope, not to implement.

## Instructions

Write the design document to this EXACT absolute path:
  $output_design_md
Do NOT write to ./design.md, design.md, or any other path. The harvester
expects the file at the absolute path above; any other location is a
contract violation that will fail this stage.

The design document MUST include:
1. A brief architectural decision summary (goal, context, decision).
2. A \`\`\`scope fenced block that is an EXHAUSTIVE enumeration of every file
   in the repository that this change touches, invalidates, references,
   validates, documents, or assumes anything about — NOT merely the seed
   scope. The seed above is a starting point, never the answer. You MUST
   actively search the repo (Read/Grep/Glob) and include:
     - every TEST that asserts behavior you are changing — INCLUDING tests
       that hardcode a value you are changing (a stage count, an event
       count, a name list, an ordering). For every constant, count, list,
       or name your change alters, GREP the repo for the OLD value and add
       every file that pins it.
     - every file that EXHAUSTIVELY ENUMERATES a set you are GROWING and would
       silently break by OMISSION. When your change adds a member to a closed
       set — a new case, branch, entry, member, route, or stage — there is NO
       old value to grep: the breakage is the MISSING new line, not a stale
       one. Find these by the ENUMERATION PATTERN, not by a value — every place
       that lists the CURRENT membership in full (a branch handling each
       member, a registry or table naming each member, a fixture or assertion
       pinning the set's SIZE or its exact roster). A downstream build that
       grows the set but leaves an exhaustive enumeration untouched ships a
       file that is now wrong by absence. If your repository defines which
       enumerations matter, consult its design override overlay below, if present.
     - every CONFIG/SCHEMA/GOLDEN that encodes a shape you are changing
       (config/, *.json, event-schema, tests/golden/, snapshots).
     - every DOC/ADR that describes the contract you are changing.
     - every SOURCE file that references a symbol you add, remove, or rename.
   A scope that merely echoes the seed is a FAILURE of this stage — the
   downstream build can only touch files you list here.

The \`\`\`scope block format (one repo-relative path per line):
\`\`\`scope
path/to/file1
path/to/file2
\`\`\`

3. A \`\`\`acceptance fenced block listing behavioral claims with STABLE NUMERIC
   IDS and CLASSIFICATION TAGS, and test file paths (TESTFILES: section). Each
   SPEC line carries a permanent id, a type tag, and describes ONE observable,
   testable behavior change this implementation must satisfy.

   CLASSIFICATION (required on every SPEC-n line):
   - \`SPEC-n[change]:\` — a NEW behavior that did not exist before; the tagged
     test MUST FAIL at the merge-base baseline and PASS after this change.
   - \`SPEC-n[guard]:\` — an INVARIANT that must not regress; do NOT contort it
     to fail at baseline. The acceptance-gate skips the negative control for
     guards.
   Unclassified \`SPEC-n:\` lines are accepted for backward compatibility but
   new designs should always classify.

   TAGGING RULE (ADR-036, enforced mechanically by the acceptance-gate stage):
   each TESTFILE must contain at least one assertion whose LABEL includes the
   matching [SPEC-n] tag, e.g. assert_eq "[SPEC-1] carry-over count" exp act.
   The gate fails the build if any SPEC-n has no [SPEC-n]-tagged assertion, AND
   it runs each [change]-tagged assertion against the merge-base baseline —
   the assertion MUST FAIL there. Write ONE SPEC per assertion so the negative
   control can isolate each behavior.

The \`\`\`acceptance block format:
\`\`\`acceptance
SPEC-1[change]: <one new behavior this change introduces>
SPEC-2[guard]: <an invariant this change must not break>
WIRING: <repo-relative-path-to-wiring-file>
TESTFILES:
SPEC-1: tests/unit/some-test.sh
SPEC-2: tests/integration/other-test.sh
\`\`\`

Per-SPEC TESTFILES binding (preferred for new designs):
- Prefix each testfile path with \`SPEC-n: \` to bind it exclusively to that SPEC.
  Example: \`SPEC-1: tests/unit/foo-test.sh\`
- Multiple paths for one SPEC: \`SPEC-1: tests/unit/a-test.sh tests/unit/b-test.sh\`
- Plain (unqualified) paths remain valid as a global fallback for backward
  compatibility, but new designs SHOULD author one \`SPEC-n: path\` line per
  \`[change]\` SPEC. This lets the gate prove each SPEC is tested by its own
  dedicated file, not a sibling's passing control.

WIRING field (ADR-036 Level-3, mandatory for behavioral-change issues):
- Declare the SEPARABLE wiring file that connects the new behavior to the
  live production call-path (e.g. the plugin registration file, the source
  directive, the dispatch table entry). This is NOT the implementation file
  itself — it is the file whose presence/modification routes the live path
  to the new implementation.
- One repo-relative path per line (multi-line WIRING: section is allowed):
    WIRING:
    plugins/agent/acceptance-gate/plugin.sh
    config/event-schema.json
- For pure-utility changes (helpers with no live dispatch path), declare
  \`WIRING: none\` to explicitly exempt the reachability check.
- The acceptance-gate will revert the declared WIRING file to the merge-base
  (keeping all other implementation changes at HEAD) and require ≥1 TESTFILE
  to flip pass→fail — proving the wiring is load-bearing, not inert.

Keep the prose focused and under 200 lines (the scope block and acceptance
block may be as long as completeness requires). Emit LOOP_COMPLETE when done.
DESIGN_PROMPT

    # design_impact_cycle feedback: on iter ≥ 2, splice prior impact gap-report
    # and prior design.md into the prompt so design EXPANDS its scope block
    # (impact feedback) and REFINES rather than re-creates (self-feedback).
    # #1825 established that this content is spliced exactly ONCE. #1979 keeps
    # that invariant with the splice moved: the engine's STAGE SUMMARIES block
    # carries design-gate's feedback now, so design only decides how to WORD the
    # refinement instruction — from the recorded verdict, not from a file read.
    local _prior_design_body
    # ADR-050 (#1826): check ZBUILD_STAGE_INPUTS for the 'design' input first —
    # input-resolve.sh already consolidates Tier-1 and Tier-2 when writing the
    # index, so we don't need to run the tier-1/tier-2 logic separately. Fall
    # back to _design_read_prior_design when the index is absent or has no entry
    # so existing test fixtures that set ZBUILD_CYCLE_FEEDBACK_DIR directly work.
    local _si_design_path=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        _si_design_path="$(jq -r '.inputs.design // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    if [[ -n "$_si_design_path" && -s "$_si_design_path" ]]; then
        _prior_design_body="$(cat "$_si_design_path" 2>/dev/null || true)"
    else
        _prior_design_body="$(_design_read_prior_design 2>/dev/null || true)"
    fi
    if [[ -n "$_prior_design_body" ]]; then
        printf '\n## PRIOR DESIGN (a previous attempt on this issue — refine, do not recreate)\n%s\n' \
            "$_prior_design_body" >> "$prompt_input_file"
        # ADR-050 (#1581): when the prior design came from a restored PRIOR RUN,
        # add a browsable pointer to its durable copy on the state branch. Guarded
        # on ZBUILD_RESTORED_ARTIFACTS_DIR so intra-cycle-only refinements (and
        # first-ever runs with no state branch) never emit a dead link.
        if [[ -n "${ZBUILD_RESTORED_ARTIFACTS_DIR:-}" ]]; then
            local _prior_design_blob; _prior_design_blob="$(_design_state_blob_url 2>/dev/null || true)"
            [[ -n "$_prior_design_blob" ]] && printf '\n(Durable copy: %s — reference it, but VERIFY against the CURRENT inputs above; the code may have moved on since.)\n' \
                "$_prior_design_blob" >> "$prompt_input_file"
        fi
        if _design_gate_failed "$artifact_dir"; then
            printf '\nExpand the PRIOR DESIGN scope block to cover the gaps the design-gate reported in the STAGE SUMMARIES section. Preserve all existing scope entries; only ADD the missing ones.\n' \
                >> "$prompt_input_file"
        else
            printf '\nRefine the PRIOR DESIGN. Preserve all existing scope entries unless one is clearly wrong.\n' \
                >> "$prompt_input_file"
        fi
    fi

    # #1219 (ADR-045/ADR-046): on a route_back REPLAY, splice the design-rooted
    # gate feedback so design RE-AUTHORS the named tautological [change] SPEC(s)
    # (build is forbidden to touch acceptance assertions, ADR-036). Keyed on file
    # presence (see reader) — absent on the first pass → no-op, byte-identical prompt.
    # #1988: the acceptance gate's detail now reaches this prompt as an
    # engine-collected summary (#1976) — the aggregator no longer renders a
    # design-facing payload, and no longer suppresses the gates that do. What
    # design still needs stated is what to DO about a specification fault, which
    # is not something a gate should be authoring prose about.
    if [[ "$(jq -r '.stage_verdicts["acceptance-gate"] // empty' \
            "$(dirname "$artifact_dir")/pipeline-state.json" 2>/dev/null || true)" == "fail" ]]; then
        printf '\nIf the STAGE SUMMARIES name a tautological [change] SPEC — one that passes at the merge-base baseline, so it asserts nothing — RE-AUTHOR that SPEC and its tagged assertion so it FAILS at baseline and PASSES at HEAD. Build is forbidden to touch acceptance assertions (ADR-036), so only this stage can. Preserve all other scope and acceptance entries.\n' \
            >> "$prompt_input_file"
    fi

    # ADR-063 §1/§2: inject budget guidance BEFORE operator overlay so the
    # operator cannot accidentally precede the shipped charter (ADR-032).
    local _budget_max_turns _budget_timeout_s _budget_elapsed_s
    _budget_max_turns="$(_route_resolve_max_turns 2>/dev/null || printf '0')"
    _budget_timeout_s="$(_route_resolve_timeout 2>/dev/null || printf '0')"
    [[ "$_budget_max_turns" =~ ^[0-9]+$ ]] || _budget_max_turns=0
    [[ "$_budget_timeout_s" =~ ^[0-9]+$ ]] || _budget_timeout_s=0
    _budget_elapsed_s=$(( SECONDS - _design_start_s ))
    local _wc_guidance _tb_guidance
    _wc_guidance="$(_design_wallclock_guidance "$_budget_timeout_s" "$_budget_elapsed_s")"
    _tb_guidance="$(_design_budget_guidance "$_budget_max_turns")"
    [[ -n "$_wc_guidance" ]] && printf '\n%s\n' "$_wc_guidance" >> "$prompt_input_file"
    [[ -n "$_tb_guidance" ]] && printf '\n%s\n' "$_tb_guidance" >> "$prompt_input_file"
    printf '\nIf you have not finished all sections when the budget nears, name the unfinished sections rather than silently omitting them — a partial design with named gaps is safer than silence.\n' >> "$prompt_input_file"

    # ADR-032: append the per-repo prompt override AFTER the core contract (so
    # the operator overlay can never precede or weaken the shipped charter).
    # Fail-open: a repo with no .zbuild/prompts/design-overrides.md appends
    # nothing and behaves byte-identically. ADR-043: redaction is owned by the
    # router — route_to_model_loop redacts each iteration's prompt (this override
    # included) by construction, using the runner-exported ZBUILD_SCOPE_MANIFEST
    # + the --scope-allowlist passed below.
    append_prompt_override "$prompt_input_file" "design"

    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier; tier="$(resolve_tier design "$_DESIGN_DIR")" || return 1
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 5)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=5

    # #825: opt into --defer-final-banner-close so the OUTPUT banner stays
    # open until we override _ROUTE_LOOP_FINAL_OUTPUT below with the actual
    # design.md content. Without the override, the banner shows claude's
    # stdout summary ("Design document written to..."), which is useless to
    # the operator. The single-file-artifact's value is the file content.
    # Mirrors build's deferred-close pattern (plugins/agent/build/plugin.sh).
    local router_rc=0
    local _prev_persona_env="${ZBUILD_STAGE_IO_PERSONA-__UNSET__}"
    if [[ "$_persona_applied" -eq 1 ]]; then
        export ZBUILD_STAGE_IO_PERSONA=architect
    else
        export ZBUILD_STAGE_IO_PERSONA=architect:fallback
    fi
    route_to_model_loop "$tier" "$prompt_input_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" \
        --defer-final-banner-close || router_rc=$?
    if [[ "$_prev_persona_env" == "__UNSET__" ]]; then
        unset ZBUILD_STAGE_IO_PERSONA
    else
        export ZBUILD_STAGE_IO_PERSONA="$_prev_persona_env"
    fi

    if [[ $router_rc -eq 130 ]]; then
        warn "_design_stage_run_inner: route_to_model_loop rc=130 (SIGINT) — propagating abort"
        return 130
    fi

    # #945: a persistent router timeout is a RECOVERABLE YIELD, not an rc.
    # route_to_model_loop absorbs repeated per-turn timeouts and RETURNS 0 with
    # _ROUTE_LOOP_TERMINATED_REASON=router_timeout (core/router/route.sh, the
    # #1208 non-fatal-timeout contract) — it does NOT return 124 to the plugin.
    # So detect the timeout via the terminated-reason signal (the same signal
    # build reads), regardless of router_rc. Do NOT converge on a stub:
    # overwrite design.md with a MINIMAL gate-FAILING marker that carries NO
    # ```acceptance block, so design-gate C2 (ACCEPTANCE_MISSING) fails and
    # design_verify_cycle RE-ITERATES rather than accepting an incomplete design
    # (ADR-021 Amendment #945). Overwriting also clears any stale design.md from
    # a prior iteration. The marker is a fixed, safe string — no scope_list
    # interpolation (avoids a ``` fence-injection) and no possibly-unset var
    # under set -u. Guard the write: only emit design.timeout.stub_written when
    # the marker actually lands; a FAILED write is a genuine filesystem/infra
    # error (not a recoverable timeout) → return 1 (terminal) rather than
    # masking it with rc=0 and leaving the cycle with no artifact.
    if [[ "${_ROUTE_LOOP_TERMINATED_REASON:-}" == "router_timeout" ]]; then
        error "_design_stage_run_inner: router loop timed out (reason=router_timeout) — writing gate-failing marker to re-iterate"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "the model call timed out before a design was returned" \
            "No design.md was authored. This is an infrastructure fault, not a design one."
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=router_timeout" "rc=$router_rc"
        mkdir -p "$artifact_dir"
        if printf '# Design incomplete — router timeout, re-iterating\n\nDesign did not complete (reason=router_timeout). No acceptance block is emitted, so the design-gate rejects this artifact and the design cycle re-iterates.\n' \
                > "$output_design_md"; then
            emit_event "design.timeout.stub_written" "plugin=design" "rc=$router_rc" "reason=router_timeout"
            # #1261: surface a did_not_finish verdict (mirroring build/#1208) so
            # the cycle sees the timeout uniformly. This is IN ADDITION to the
            # gate-failing marker above (which still drives #945 re-iteration on
            # non-final iters). At exhaustion, a did_not_finish TAIL lets the
            # cycle HALT (design_timeout_exhausted) instead of falling through to
            # build with an empty design. Non-fatal (the marker above still drives
            # #945 re-iteration), but a FAILED write must be VISIBLE — this sidecar
            # is the load-bearing exhaustion-halt signal; silently dropping it
            # would degrade to the pre-#1261 empty-design fall-through with no
            # trace. Mirror the #945 marker-write's fail-loud handling via warn.
            printf '{"result_contract":2,"verdict":"incomplete","disposition":"interrupted","reason":"router_timeout"}\n' \
                > "$design_verdict_sidecar" 2>/dev/null \
                || warn "_design_stage_run_inner: failed to write incomplete sidecar $design_verdict_sidecar (timeout-exhaustion halt may not fire)"
            return 0
        fi
        error "_design_stage_run_inner: failed to write timeout marker to $output_design_md"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "could not record the design marker" \
            "A design may have been authored but could not be committed to the artifact dir."
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=marker_write_failed" "rc=$router_rc"
        return 1
    fi

    if [[ $router_rc -ge 2 ]]; then
        # Genuine loop error (rc=2) or an OOM/other non-zero rc — TERMINAL. (The
        # rc=124 sub-case of _router_rc_classify is defensive only: the loop
        # yields a timeout as return-0 + reason=router_timeout, handled above,
        # so rc=124 does not reach here in production.)
        local _rc_verdict _rc_reason
        _router_rc_classify "$router_rc" _rc_verdict _rc_reason
        error "_design_stage_run_inner: router rc=$router_rc → verdict=$_rc_verdict reason=$_rc_reason"
        _design_write_result "$artifact_dir" "error" "broken" "$_rc_reason"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "the model call failed ($_rc_reason)" \
            "No usable design.md was returned."
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=$_rc_reason" "rc=$router_rc"
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
                _design_write_result "$artifact_dir" "error" "broken" "stray_conflict"
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
        _design_write_result "$artifact_dir" "error" "broken" "missing_design_md"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "no design.md was produced" \
            "The model returned without writing the artifact this stage exists to produce."
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=missing_design_md"
        return 1
    fi

    # #817: single-quoted backticks need no escaping. Prior pattern
    # '^\`\`\`scope' worked on macOS BSD grep (silently drops unknown \X
    # escapes) but failed on Linux GNU grep (treats \` as backslash+backtick).
    # Use plain literal triple-backticks; the existing _extract_scope_from_design
    # below already uses the unescaped form, so this aligns the two.
    if ! grep -q '^```scope' "$output_design_md" 2>/dev/null; then
        warn "_design_stage_run_inner: design.md missing scope block — design output incomplete"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "design.md has no fenced scope block" \
            "Without a scope block the build stage has no declared boundary to work inside."
        _design_write_result "$artifact_dir" "error" "broken" "missing_scope_block"
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=missing_scope_block"
        # Failure path: don't override the banner output; let the deferred
        # close (if any) flush claude's stdout summary so the operator sees
        # the LLM's diagnostic message rather than a missing-file artifact.
        if declare -F _route_loop_close_final_banner >/dev/null 2>&1; then
            _route_loop_close_final_banner || true
        fi
        return 1
    fi

    # Assert the acceptance block is present in design.md.
    if ! extract_acceptance_block "$output_design_md" >/dev/null 2>&1; then
        warn "_design_stage_run_inner: design.md missing acceptance block — design output incomplete"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "design.md has no fenced acceptance block" \
            "Without acceptance SPECs there is nothing for the acceptance gate to verify."
        _design_write_result "$artifact_dir" "error" "broken" "missing_acceptance_block"
        emit_event "plugin.result" "verdict=error" "plugin=design" "reason=missing_acceptance_block"
        if declare -F _route_loop_close_final_banner >/dev/null 2>&1; then
            _route_loop_close_final_banner || true
        fi
        return 1
    fi

    # #825: override the OUTPUT banner payload with the actual design.md
    # content BEFORE flushing the deferred-close banner. Without this,
    # the banner shows claude's stdout summary ("Design document written
    # to...") rather than the on-disk artifact. The single-file-artifact's
    # value IS the file content; show that to the operator. Existing
    # stage-io tail-N truncation handles long files naturally (40-line tail
    # + "full at <path>" hint).
    if declare -F _route_loop_close_final_banner >/dev/null 2>&1; then
        _ROUTE_LOOP_FINAL_OUTPUT="$(cat "$output_design_md" 2>/dev/null || true)"
        _route_loop_close_final_banner || true
    fi

    # v2 result contract (#1834): write sidecar BEFORE atomic_write of design.md
    # so the sidecar is always on disk when rc=0 (SPEC-1).
    _design_write_result "$artifact_dir" "pass" "complete" "design_produced"

    # Atomically finalize design.md (#507 contract).
    cat "$output_design_md" | atomic_write "$output_design_md"

    # ADR-055 §9: state the SHAPE of the design a later stage is held to —
    # the boundary it may touch and the SPECs it must satisfy.
    local _scope_csv="" _scope_n=0 _acc="" _spec_n=0
    _scope_csv="$(_extract_scope_from_design "$output_design_md" 2>/dev/null || true)"
    [[ -n "$_scope_csv" ]] && _scope_n="$(awk -F, '{print NF}' <<< "$_scope_csv")"
    _acc="$(extract_acceptance_block "$output_design_md" 2>/dev/null || true)"
    _spec_n="$(grep -c '^SPEC-[0-9]' <<< "$_acc" || true)"
    stage_summary_write "$artifact_dir/design-summary.md" "design" "pass" \
        "authored design.md — $_scope_n file(s) in scope, $_spec_n acceptance SPEC(s)" \
        "$(printf -- '- scope: %s\n- artifact: design.md' "${_scope_csv:-<none>}")"
    emit_event "plugin.result" "stage=design" \
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
        # Tolerate trailing whitespace on the fence lines — legacy used
        # /^```scope[[:space:]]*$/, and build's guard (grep -q '^```scope')
        # matches a whitespace-padded fence, so an exact match here would
        # silently drop the scope and fall back to plan.json (#25 review).
        if [[ "$line" =~ ^'```scope'[[:space:]]*$ ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" =~ ^'```'[[:space:]]*$ ]]; then
            break
        fi
        # Keep lines with any non-whitespace; drop whitespace-only lines
        # (faithful to legacy `grep -v '^[[:space:]]*$'`).
        if [[ $in_block -eq 1 && -n "${line//[[:space:]]/}" ]]; then
            files+=("$line")
        fi
    done < "$design_md"

    if [[ ${#files[@]} -gt 0 ]]; then
        local IFS=','
        printf '%s' "${files[*]}"
    fi
}

# ─── cleanup ────────────────────────────────────────────────────────────────
