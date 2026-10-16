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
# #2366: one outcome from the engine's list, through the one writer.
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_DESIGN_ROOT/scripts/lib/stage-result.sh"
# #2369: design checks its own design.md — by script, then by a second model call.
# shellcheck source=./lib/checks.sh
source "$_DESIGN_DIR/lib/checks.sh"
# shellcheck source=./lib/coverage.sh
source "$_DESIGN_DIR/lib/coverage.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_DESIGN_ROOT/scripts/lib/earlier-output.sh"

# _design_write_outcome <artifact_dir> <outcome> <reason> [findings_json]
# Writes design-verdict.json (#2366: one outcome from the engine's list).
# Called on every terminal exit path so the sidecar is always on disk. #2369:
# what design's checks still find is carried as numbered findings.
_design_write_outcome() {
    local dir="$1" outcome="$2" reason="$3" findings="${4:-[]}"
    mkdir -p "$dir" 2>/dev/null || true
    # #2172: the design is stamped with WHEN and against WHICH commit it was
    # written, so a later run that inherits it can say what moved since. The
    # date is what the next run keys on — the work branch is rebased between
    # runs and old commits stop being reachable; a date survives that.
    local _at _sha
    _at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _sha="$(git -C "${ZBUILD_REPO_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)"
    # #2189: the design REPORTS the files its contract wires, so the engine never
    # reads design.md by path to learn them.
    local _wiring="[]"
    if [[ -s "$dir/design.md" ]] && declare -F acceptance_list_wiring >/dev/null 2>&1; then
        # Captured first: under pipefail a failing lister would otherwise append
        # a second '[]' to jq's and leave invalid JSON. `WIRING: none` is no file.
        local _wl; _wl="$(acceptance_list_wiring "$dir/design.md" 2>/dev/null || true)"
        _wiring="$(jq -Rnc '[inputs | select(length > 0 and . != "none")] | unique' <<< "$_wl" 2>/dev/null || true)"
        [[ -n "$_wiring" ]] || _wiring="[]"
    fi
    # #1874: and the files it scoped the change to — so the engine's one scope
    # list is the one build works to, not plan's alone.
    local _scope="[]"
    if [[ -s "$dir/design.md" ]] && declare -F acceptance_list_scope >/dev/null 2>&1; then
        local _sl; _sl="$(acceptance_list_scope "$dir/design.md" 2>/dev/null || true)"
        _scope="$(jq -Rnc '[inputs | select(length > 0)]' <<< "$_sl" 2>/dev/null || true)"
        [[ -n "$_scope" ]] || _scope="[]"
    fi
    local _data
    _data="$(jq -nc --arg at "$_at" --arg sha "$_sha" \
        --argjson w "${_wiring:-[]}" --argjson sc "${_scope:-[]}" --argjson f "$findings" \
        '{authored_at: $at, authored_at_commit: $sha, wiring_files: $w}
         + (if ($sc | length) > 0 then {scope_files: $sc} else {} end)
         + (if ($f | length) > 0 then {findings: $f} else {} end)')"
    stage_result_write "$dir/design-verdict.json" "$outcome" "$reason" "$_data" 2>/dev/null \
        || warn "_design_write_outcome: failed to write design-verdict.json (outcome=$outcome)"
}

# ─── run ────────────────────────────────────────────────────────────────────
# #2154: SPEC declarations only. The acceptance block's TESTFILES section binds
# each SPEC on a line that also starts `SPEC-n:`; counting those doubled the
# number in the run-status comment (38 for a 19-SPEC design on #1840 run 5).
_design_spec_count() {
    local n
    n="$(acceptance_list_spec_ids "$1" 2>/dev/null | grep -c . || true)"
    printf '%s' "${n:-0}"
}

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

    # #2364: the scope manifest and the work plan, found by what they contain
    # among every earlier output (ADR-055 §1).
    local scope_manifest plan_json_path
    scope_manifest="$(earlier_scope_manifest "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    plan_json_path="$(earlier_work_plan "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    _design_stage_run_inner \
        "$scope_manifest" \
        "$plan_json_path" \
        "$artifacts_dir/design.md" \
        "$artifacts_dir"
}


# Design's prior design, to refine rather than re-create: its own latest
# design.md, whichever try or run wrote it — hydrate puts an earlier run's back
# in place (ADR-050, ADR-068 §8). _design_prior_design_path prints the path; the
# reader cats it.
_design_prior_design_path() {
    local own="${1:-}"
    [[ -n "$own" && -s "$own" ]] && printf '%s' "$own"
    return 0
}
_design_read_prior_design() {
    local f; f="$(_design_prior_design_path "${1:-}")"
    [[ -n "$f" ]] && cat "$f" 2>/dev/null
    return 0
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

    # #1261: the did_not_finish verdict sidecar (mirrors build's #1208 mid-flight
    # verdict). Cleared at the START of every run so a stale timeout verdict from
    # a PRIOR iteration can never leak into a later iteration that produced a real
    # design.md — the cycle would otherwise wrongly read did_not_finish and
    # halt-exhaust on a content-converging run. Written ONLY on a router timeout
    # below. verdict.sh reads it as design's raw verdict for the cycle.
    local design_verdict_sidecar="$artifact_dir/design-verdict.json"
    rm -f "$design_verdict_sidecar"

    # #2299 (ADR-050 §6): design always runs. A restored prior design reaches
    # the prompt below as a reference to check — never this run's design as is.
    # #2035 run 37289704344 kept an untested design in 1 second.

    if [[ ! -f "$plan_json_path" ]]; then
        error "_design_stage_run_inner: no work plan found (looked for: ${plan_json_path:-nothing given})"
        _design_write_outcome "$artifact_dir" "broken" "missing_plan_json"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "no work plan to design against" \
            "The plan stage produced nothing this stage could read; no design was authored."
        emit_event "plugin.result" "outcome=broken" "plugin=design" "reason=missing_plan_json"
        return 1
    fi

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # plan.files[] and the work items' areas (#2363): the seed scope for
    # design.md's scope block.
    local plan_files_csv=""
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // []), ([.steps[]?.areas[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    local scope_list=""
    if [[ -n "$plan_files_csv" ]]; then
        scope_list="$(printf '%s' "$plan_files_csv" | tr ',' '\n' | sed 's/^/- /')"
    fi

    local prompt_input_file="$artifact_dir/design-prompt.txt"

    # The persona (ADR-051) reaches the model through the provider, not this
    # text: the stage writes only its own job.
    local _framing="Your job: write design.md — the change's decisions, its acceptance contract and its scope — at the path below. Write a first version early and update it as you go: a design on disk when your time runs out still counts. A finding is answered in the design: what changes in the contract or the scope. You do not debug code or work out why a test fails."

    cat > "$prompt_input_file" <<DESIGN_PROMPT
## What you own
${_framing}

Write the design document to this EXACT absolute path:
  $output_design_md

The design document MUST include:
1. A brief architectural decision summary (goal, context, decision).
2. A \`\`\`scope fenced block listing every file this change touches, and every
   file that pins what it changes. Find them by searching: search for the names, values and lists the change alters (Grep and Glob), rather than reading
   files end to end. Include:
     - the tests that assert a behaviour you change, or pin a value, count,
       name list or order you change (search for the old value);
     - when the change adds a member to a set (a case, entry, route, stage),
       the files that list every current member — a table, a registry, a
       fixture or an assertion pinning the set's size or its roster;
     - the config, schema and golden files that encode a shape you change;
     - the docs and ADRs that describe the contract you change;
     - the source files that use a name you add, remove or rename.
   The seed below is a starting point. The files you list are the files the
   change may touch.

The \`\`\`scope block format (one repo-relative path per line):
\`\`\`scope
path/to/file1
path/to/file2
\`\`\`

3. A \`\`\`acceptance block listing what this change must deliver. Each line is
   one requirement: a permanent number (SPEC-1, SPEC-2, …), a status, and ONE
   behaviour someone could observe and test.

   The status says what work the requirement needs. Look at the code before you choose:
   - \`SPEC-n[code]:\` — it needs code. Its test must fail on the code as it is before your change, and pass after it.
     If the code already does it, it is not [code]: its test would already pass, and the build stalls on it.
     A [code] requirement describes what the code does, not what a file contains: not "x.sh contains foo" or "file y exists".
   - \`SPEC-n[no-code]:\` — it needs work that changes no behaviour: docs, a
     test, config, or a refactor. Its test must pass after the change; it need not fail before.
   - \`SPEC-n[done]:\` — the code already does it. Name the evidence at the end of the line, after \` evidence: \` —
     a file and line (scripts/x.sh:42) or an existing test file, by its path from the repository root,
     several separated by spaces. Each must exist; a line number must be inside its file. No test is written for it.
   Every requirement carries one of the three. A change that edits code needs at least one [code] requirement.

   Test labels: each test file under TESTFILES holds at least one assertion
   whose label carries the requirement's tag, which includes this issue's
   number — for SPEC-1 of this issue:
   $(acceptance_spec_tag SPEC-1 2>/dev/null || printf '[SPEC-1]'). A shared test
   may already hold other issues' tags; leave them alone. Each [code]
   assertion is also run against the code from before your change and must
   fail there, so write ONE requirement per assertion — then each behaviour is
   checked on its own.

The \`\`\`acceptance block format:
\`\`\`acceptance
SPEC-1[code]: <one new behaviour this change introduces>
SPEC-2[no-code]: <docs, a test, config or a refactor that changes no behaviour>
SPEC-3[done]: <something the code already does> evidence: scripts/x.sh:42
WIRING: <the existing file that calls the new code>
TESTFILES:
SPEC-1: tests/unit/some-test.sh
SPEC-2: tests/integration/other-test.sh
\`\`\`

Bind each test file to its requirement:
- Prefix the path with \`SPEC-n: \`, e.g. \`SPEC-1: tests/unit/foo-test.sh\`.
- Several paths for one requirement: \`SPEC-1: tests/unit/a-test.sh tests/unit/b-test.sh\`
- Write one \`SPEC-n: path\` line per [code] requirement, so each requirement
  is proven by its own test file. A [done] requirement needs none. A path with
  no \`SPEC-n:\` prefix applies to every requirement.

WIRING: Which existing file calls the new code?
- Name the file in your scope whose code calls (or loads) the new behaviour:
  the place a running program reaches it from. It is not the file that
  implements the behaviour. If that file were put back to how it is today, at
  least one of your test files would fail.
- A list, schema or config entry is never this file: adding a name to an event
  list, a schema or a config list changes no behaviour on its own. A list entry
  your change needs belongs in the scope block.
- One path per line; several lines are allowed:
    WIRING:
    plugins/agent/build/plugin.sh
    core/pipeline/runner.sh
- If nothing calls the new code yet (a helper used later), write
  \`WIRING: none\`.
- After the build, the file you name is put back to its old version (everything
  else kept), and at least one test must then fail. That is how the pipeline
  checks you named the right file.

Existing checks this change makes wrong: when the change alters a
behaviour an EXISTING assertion pins (one that is not a SPEC of this contract),
list it in a \`\`\`supersedes block — one line per check, the testfile path,
the assertion's tag, and why it is now wrong:
\`\`\`supersedes
tests/unit/foo-test.sh [SPEC-3]: \`verdict\` is now the v2 result's status key, not a merge decision
\`\`\`
Updating those checks to the new behaviour is part of writing the tests. Omit
the block when no existing check changes meaning.

Keep the prose focused and under 200 lines (the scope block and acceptance
block may be as long as completeness requires). Emit LOOP_COMPLETE when done.

## What you judge against
The issue, and the plan drawn from it, may describe a solution as well as the
problem. A section that records a decision (for example "Decision:") is binding: follow it.
Anything else they propose — an approach, a file list, a scope, a claim that
some files or tests are unaffected — is a starting point, not the answer: check
it against the code yourself and come up with your own design. Where yours
differs, say why.

### Plan
$(printf '%s' "$plan_json" | jq -r '.title // "Untitled"' 2>/dev/null)

$(printf '%s' "$plan_json" | jq -r '.description // .goal // ""' 2>/dev/null)

### Seed scope (from plan.files[])
${scope_list}

### Tools
- You MAY use the Read tool to inspect any file in the repository.
- You MAY use the Grep tool to search the whole repository for symbols,
  constants, references, and hardcoded values.
- You MAY use the Glob tool to discover files by pattern.
DESIGN_PROMPT
    # #2306 (ADR-070 §3): the issue's requirements, numbered by the engine; every
    # one is covered by a SPEC, and design's own checks see to that by script.
    # #2364: found by what it contains.
    local _req_f _reqs; _req_f="$(earlier_requirements "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    _reqs="$(acceptance_requirements_list "$_req_f")"
    [[ -n "$_reqs" ]] && printf '\n### Requirements from the issue (numbered by the engine)\n%s\n\nEvery requirement above must be covered by at least one SPEC. End each SPEC line with ` covers: ` and the ids of the requirements it covers, before any ` evidence: ` — for example `SPEC-1[code]: <behaviour> covers: R-1 R-2`. A requirement the code already meets is covered by a [done] SPEC with evidence.\n' "$_reqs" >> "$prompt_input_file"

    # On a later round design REFINES its prior design.md rather than
    # re-creating it. #1825 established that this content is spliced exactly ONCE. #1979 keeps
    # that invariant with the splice moved: the engine's Previous work carries
    # the design check's findings, so design only decides how to WORD the
    # refinement instruction — from the recorded verdict, not from a file read.
    local _prior_design_body=""
    # Design refines its own latest design.md, whichever try or run wrote it
    # (ADR-068 §8): a rerun of an issue continues it. What moved since design
    # last ran — files and the issue text — is the engine's, under Previous
    # work; every claim is checked against the tree as it is now.
    local _si_design_path=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        _si_design_path="$(jq -r '.inputs.design // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    if [[ -z "$_si_design_path" || ! -s "$_si_design_path" ]]; then
        _si_design_path="$(_design_prior_design_path "$output_design_md" 2>/dev/null || true)"
    fi
    [[ -n "$_si_design_path" ]] && _prior_design_body="$(cat "$_si_design_path" 2>/dev/null || true)"
    if [[ -n "$_prior_design_body" ]]; then
        printf '\n### YOUR LATEST DESIGN (refine it; Previous work says what moved since you wrote it)\n' >> "$prompt_input_file"
        printf 'Every claim it makes about the repository — an ADR it relies on, a file it lists, a hook, field or convention it declares — is re-checked against the tree as it is NOW; anything that no longer holds is dropped or re-derived, and the design says what changed and why. Keep what still holds; do not start over.\n' >> "$prompt_input_file"
        printf '\n%s\n' "$_prior_design_body" >> "$prompt_input_file"
        printf '\nRefine YOUR LATEST DESIGN. Preserve all existing scope entries unless one is clearly wrong.\n' \
            >> "$prompt_input_file"
    fi

    # When a later check found a [code] requirement whose test already passes,
    # say what design can do about it (build may not touch acceptance
    # assertions, ADR-036). #2304 (ADR-069): no relabel offer — [done] needs
    # evidence design's own checks look at. #2372: said whenever design refines
    # an earlier design — the condition is in the words ("If Previous work
    # says"), never in another stage's verdict.
    if [[ -n "$_prior_design_body" ]]; then
        # #2269: plain words; no other stage named (ADR-061), no ADR number.
        printf '\nIf Previous work says a [code] requirement'"'"'s test already passes on the code from before this change, rewrite that requirement so its test fails on the old code and passes after — or, if the code already does it, mark it [done] and name the evidence (a file and line, or an existing test file) after " evidence: ". The evidence is checked. The tests cannot be changed later in this run, so this is where it is fixed. Check the other scope and acceptance entries against the feedback too, and fix any it shows is wrong.\n' \
            >> "$prompt_input_file"
    fi

    # #2308: the limits close the stage's own text. #2369: kept apart, so each
    # round can add what the checks found before them.
    local _dp_stage_text _dp_limits
    _dp_stage_text="$(cat "$prompt_input_file")"
    _dp_limits="$(cat <<DESIGN_LIMITS

## What you must not do
- Do not write any file other than the design.md above and your notes file.
  Do not change the code: the design says what changes, it does not make the
  change.
- Do not write design.md anywhere else (./design.md, design.md): it is read
  from the absolute path above only.
DESIGN_LIMITS
)"

    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier; tier="$(resolve_tier design "$_DESIGN_DIR")" || return 1
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 5)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=5
    # #2369: design's own rounds of checking its design.md, from its manifest.
    local _rounds; _rounds="$(yaml_get "$_DESIGN_DIR/manifest.yaml" config.check_rounds 2>/dev/null || true)"
    [[ "$_rounds" =~ ^[1-9][0-9]*$ ]] || _rounds=2
    # _ours: design.md on disk is this run's own — a round produced it. Only an
    # earlier run's copy is stale; this run's is never removed (#2369).
    local _round=1 _found="" _ours=0

    while :; do
    # ADR-067 §8: design's three parts and the engine's blocks — the
    # repository's guidance for design, its budget and notes file — in the one
    # prompt order.
    local _dp_composed
    if ! _dp_composed="$(stage_prompt_compose_parts "${_dp_stage_text}${_found}
${_dp_limits}")"; then
        error "_design_stage_run_inner: the prompt could not be composed — the engine's blocks are missing"
        return 1
    fi
    printf '%s\n' "$_dp_composed" > "$prompt_input_file"

    # #825: opt into --defer-final-banner-close so the OUTPUT banner stays
    # open until we override _ROUTE_LOOP_FINAL_OUTPUT below with the actual
    # design.md content. Without the override, the banner shows claude's
    # stdout summary ("Design document written to..."), which is useless to
    # the operator. The single-file-artifact's value is the file content.
    # Mirrors build's deferred-close pattern (plugins/agent/build/plugin.sh).
    local router_rc=0
    # #2186: what design.md was before THIS call — on a timeout, whether the call
    # wrote a new design is the one fact that decides what gets published.
    local _design_before; _design_before="$(cksum 2>/dev/null < "$output_design_md" || printf 'absent')"
    route_to_model_loop "$tier" "$prompt_input_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" \
        --defer-final-banner-close || router_rc=$?


    if [[ $router_rc -eq 130 ]]; then
        warn "_design_stage_run_inner: route_to_model_loop rc=130 (SIGINT) — propagating abort"
        return 130
    fi

    # #945/#1208: a persistent router timeout is a RECOVERABLE YIELD — the loop
    # returns 0 and says so in _ROUTE_LOOP_TERMINATED_REASON=router_timeout.
    # #2186: what gets published depends only on what THIS call did to
    # design.md. Never fabricate a design (the #945 marker overwrote a complete
    # one on #1849, run 35949629759):
    #   - changed by this call → keep it as written and check it (#2369).
    #   - unchanged → publish nothing: remove the stale copy so an earlier
    #     pass's design is not taken as this one's; the loop goes round. A copy
    #     that cannot be removed is terminal.
    # Either way the sidecar says incomplete/interrupted (#1261), which the
    # cycle reads as "this iteration did not finish".
    if [[ "${_ROUTE_LOOP_TERMINATED_REASON:-}" == "router_timeout" ]]; then
        local _design_after; _design_after="$(cksum 2>/dev/null < "$output_design_md" || printf 'absent')"
        mkdir -p "$artifact_dir"
        if [[ -s "$output_design_md" && ( "$_design_after" != "$_design_before" || $_ours -eq 1 ) ]]; then
            # A design on disk when the time runs out still counts: it is
            # checked like any other (#2369), and the checks decide.
            warn "_design_stage_run_inner: router loop timed out after writing design.md — keeping it and checking it"
            emit_event "design.timeout.design_kept" "plugin=design" "reason=router_timeout"
        else
            error "_design_stage_run_inner: router loop timed out without writing a design — publishing none"
            if ! rm -f "$output_design_md" 2>/dev/null || [[ -e "$output_design_md" ]]; then
                error "_design_stage_run_inner: could not remove the stale design at $output_design_md"
                stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                    "a stale design could not be removed" \
                    "An earlier pass's design.md is still on disk and would be judged as this one's."
                emit_event "plugin.result" "outcome=broken" "plugin=design" "reason=stale_design_not_removed" "rc=$router_rc"
                _design_write_outcome "$artifact_dir" "broken" "stale_design_not_removed"
                return 1
            fi
            stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                "Design ran out of time before writing design.md." \
                "No design.md was written."
            emit_event "plugin.result" "outcome=timed_out" "plugin=design" "reason=router_timeout" "rc=$router_rc"
            emit_event "design.timeout.no_design" "plugin=design" "reason=router_timeout"
            stage_result_write "$design_verdict_sidecar" timed_out "router_timeout" 2>/dev/null \
                || warn "_design_stage_run_inner: failed to write the timed-out result $design_verdict_sidecar (timeout-exhaustion halt may not fire)"
            return 0
        fi
    fi

    # #2111: the router hit the account's rate limit. Say so in the result —
    # `unavailable` ends the run as aborted/llm_rate_limited (resumable) —
    # instead of falling through to "no design" and a gate-driven re-iteration.
    if [[ "${_ROUTE_LOOP_TERMINATED_REASON:-}" == "router_rate_limited" ]]; then
        error "_design_stage_run_inner: router loop rate-limited (${_ROUTE_LOOP_RATE_LIMIT_MESSAGE:-LLM rate-limited})"
        _design_write_outcome "$artifact_dir" "rate_limited" "router_rate_limited"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "the model call was rate-limited (${_ROUTE_LOOP_RATE_LIMIT_MESSAGE:-LLM rate-limited})" \
            "No design.md was authored. The run ends here and resumes when the limit resets."
        emit_event "plugin.result" "outcome=rate_limited" "plugin=design" "reason=router_rate_limited" "rc=$router_rc"
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
        _design_write_outcome "$artifact_dir" "$(router_reason_disposition "$_rc_reason")" "$_rc_reason"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "the model call failed ($_rc_reason)" \
            "No usable design.md was returned."
        emit_event "plugin.result" "outcome=$(router_reason_disposition "$_rc_reason")" "plugin=design" "reason=$_rc_reason" "rc=$router_rc"
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
                _design_write_outcome "$artifact_dir" "unusable" "stray_conflict"
                stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                    "design.md was written to the repo root, where a tracked file already lives" \
                    "The model ignored the destination path in the prompt. The root design.md is git-tracked and operator-owned, so it is left untouched and no design artifact was produced."
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
        _design_write_outcome "$artifact_dir" "unusable" "missing_design_md"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
            "no design.md was produced" \
            "The model returned without writing the artifact this stage exists to produce."
        emit_event "plugin.result" "outcome=unusable" "plugin=design" "reason=missing_design_md"
        return 1
    fi

    # #825: show the operator the design.md this round wrote, not the model's
    # stdout summary ("Design document written to..."). Existing stage-io tail-N
    # truncation handles long files.
    if declare -F _route_loop_close_final_banner >/dev/null 2>&1; then
        _ROUTE_LOOP_FINAL_OUTPUT="$(cat "$output_design_md" 2>/dev/null || true)"
        _route_loop_close_final_banner || true
    fi

    # #2369: design checks its own design.md — by script, then, when the issue
    # has numbered requirements, by a second model call that asks whether the
    # SPECs cover them. What fails goes back to the model until it clears or the
    # rounds run out.
    local -a _fnd=()
    local _v _u
    _ours=1
    _design_checks "$output_design_md" "$repo_root" "$_req_f"
    for _v in "${_DESIGN_VIOLATIONS[@]}"; do _fnd+=("$(_dck_plain "$_v")"); done
    if [[ -n "$_reqs" ]] && extract_acceptance_block "$output_design_md" >/dev/null 2>&1; then
        _design_coverage "$output_design_md" "$_reqs" "$tier"
        if [[ -n "$_DESIGN_COV_OUTCOME" ]]; then
            error "_design_stage_run_inner: the coverage check could not be run ($_DESIGN_COV_OUTCOME)"
            _design_write_outcome "$artifact_dir" "$_DESIGN_COV_OUTCOME" "coverage_check_failed"
            stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                "the check that the design covers the issue could not be run ($_DESIGN_COV_OUTCOME)" \
                "design.md is kept as written, unchecked."
            emit_event "plugin.result" "outcome=$_DESIGN_COV_OUTCOME" "plugin=design" "reason=coverage_check_failed"
            return 1
        fi
        for _u in "${_DESIGN_UNCOVERED[@]}"; do _fnd+=("The issue asks for this and no SPEC covers it: $_u"); done
    fi
    [[ ${#_fnd[@]} -eq 0 ]] && break

    emit_event "design.checks.failed" "plugin=design" "round=$_round" "rounds=$_rounds" "findings=${#_fnd[@]}"
    if (( _round >= _rounds )); then
        local _fj; _fj="$(printf '%s\n' "${_fnd[@]}" | stage_findings_json)"
        _design_write_outcome "$artifact_dir" "fail" "design.md still fails its checks after $_rounds rounds" "${_fj:-[]}"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "fail" \
            "design.md still fails ${#_fnd[@]} check(s) after $_rounds rounds" \
            "$(printf -- '- %s\n' "${_fnd[@]}")"
        emit_event "plugin.result" "outcome=fail" "plugin=design" "reason=checks_failed"
        return 0
    fi
    _round=$(( _round + 1 ))
    _found="$(printf '\n### What your design'"'"'s checks found (round %s of %s)\nYour design.md at the path above was checked, and these do not hold. Fix each one in design.md; keep what already passes.\n' "$_round" "$_rounds"; printf -- '- %s\n' "${_fnd[@]}")"
    done

    # v2 result contract (#1834): write sidecar BEFORE atomic_write of design.md
    # so the sidecar is always on disk when rc=0 (SPEC-1).
    _design_write_outcome "$artifact_dir" "pass" "design_produced"

    # Atomically finalize design.md (#507 contract).
    atomic_write "$output_design_md" < "$output_design_md"

    # ADR-055 §9: state the SHAPE of the design a later stage is held to —
    # the boundary it may touch and the SPECs it must satisfy.
    local _scope_csv="" _scope_n=0 _spec_n=0
    _scope_csv="$(_extract_scope_from_design "$output_design_md" 2>/dev/null || true)"
    [[ -n "$_scope_csv" ]] && _scope_n="$(awk -F, '{print NF}' <<< "$_scope_csv")"
    _spec_n="$(_design_spec_count "$output_design_md")"
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
