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
# Persona resolver + stage/lens composition seam (#1304, #1324).
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_DESIGN_ROOT/core/plugin-registry/registry.sh"
# #963: read-only grammar lib from _ZBUILD_CONTRACT_LIB_DIR (self-host redirect).
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh"

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

# design_impact_cycle iter ≥ 2: read impact's gap report from cycle feedback.
# Returns raw markdown body on stdout; empty when no cycle context or no file.
_design_read_prior_impact_feedback() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    [[ "$iter" =~ ^[0-9]+$ ]] || return 0
    (( iter < 2 )) && return 0
    local f="$fb_dir/prior_impact_feedback.txt"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s' "$body"
}

# #1219 (ADR-045/ADR-046): design-rooted gate feedback carried back by the
# build_test_cycle route_back rewind. Unlike prior_impact_feedback (intra-cycle,
# gated on ZBUILD_CYCLE_ITER≥2), this arrives from the OTHER cycle via the shared
# artifacts dir (design-feedback.md), so it is keyed on FILE PRESENCE, not the
# design_verify_cycle iteration counter: on the FIRST design pass the file is
# absent (no-op); after a route_back it is present and design re-authors the SPEC.
_design_read_prior_gate_feedback() {
    local artifact_dir="${1:-}"
    [[ -z "$artifact_dir" ]] && return 0
    local f="$artifact_dir/design-feedback.md"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s' "$body"
}

# design_impact_cycle self-feedback (mirrors #773 lesson): design's own prior
# design.md body for iter N+1 to refine rather than re-create.
_design_read_prior_design() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    [[ "$iter" =~ ^[0-9]+$ ]] || return 0
    (( iter < 2 )) && return 0
    local f="$fb_dir/prior_design.txt"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s' "$body"
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

    # Persona seam (#1324): open the prompt with the architect persona's framing
    # when its manifest is present; when absent, persona_stage_framing returns 1
    # and we fall back to the exact pre-#1324 opening — BYTE-IDENTICAL, including
    # the original mid-sentence line wrap after "produce an".
    local _task_intro="Your job is to produce an ADR-style design.md for the task described in the plan below."
    local _framing
    _framing="$(persona_stage_framing architect "$_task_intro" "$_DESIGN_ROOT/plugins" 2>/dev/null)" \
        || _framing="You are a software architect for the target project. Your job is to produce an
ADR-style design.md for the task described in the plan below."

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
    local _impact_fb_body
    _impact_fb_body="$(_design_read_prior_impact_feedback 2>/dev/null || true)"
    local _prior_design_body
    _prior_design_body="$(_design_read_prior_design 2>/dev/null || true)"
    if [[ -n "$_impact_fb_body" ]]; then
        printf '\n## PRIOR IMPACT FEEDBACK (from previous design_impact_cycle iter)\n%s\n' \
            "$_impact_fb_body" >> "$prompt_input_file"
    fi
    if [[ -n "$_prior_design_body" ]]; then
        printf '\n## PRIOR DESIGN (your previous iteration — refine, do not recreate)\n%s\n' \
            "$_prior_design_body" >> "$prompt_input_file"
        if [[ -n "$_impact_fb_body" ]]; then
            printf '\nExpand the PRIOR DESIGN scope block to cover the gaps named in PRIOR IMPACT FEEDBACK. Preserve all existing scope entries; only ADD the missing ones.\n' \
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
    local _gate_fb_body
    _gate_fb_body="$(_design_read_prior_gate_feedback "$artifact_dir" 2>/dev/null || true)"
    if [[ -n "$_gate_fb_body" ]]; then
        printf '\n## PRIOR GATE FEEDBACK (design-rooted — from the acceptance gate, via route_back)\n%s\n' \
            "$_gate_fb_body" >> "$prompt_input_file"
        printf '\nThe acceptance gate found the named SPEC(s) tautological (they pass at the merge-base baseline, so they assert nothing). RE-AUTHOR each named [change] SPEC and its tagged assertion so it FAILS at baseline and PASSES at HEAD. Preserve all other scope and acceptance entries.\n' \
            >> "$prompt_input_file"
    fi

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
    route_to_model_loop "$tier" "$prompt_input_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" \
        --defer-final-banner-close || router_rc=$?

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
        emit_event "plugin.run.error" "plugin=design" "reason=router_timeout" "rc=$router_rc"
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
            printf '{"schema_version":1,"verdict":"did_not_finish","reason":"router_timeout"}\n' \
                > "$design_verdict_sidecar" 2>/dev/null \
                || warn "_design_stage_run_inner: failed to write did_not_finish sidecar $design_verdict_sidecar (timeout-exhaustion halt may not fire)"
            return 0
        fi
        error "_design_stage_run_inner: failed to write timeout marker to $output_design_md"
        emit_event "plugin.run.error" "plugin=design" "reason=marker_write_failed" "rc=$router_rc"
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
        emit_event "plugin.run.error" "plugin=design" "reason=$_rc_reason" "rc=$router_rc"
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
        emit_event "plugin.run.error" "plugin=design" "reason=missing_acceptance_block"
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
