#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/design — Design stage agent (issue #754)                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: design (ADR-013 T2, single-file artifact). One model call per run
# (ADR-068 §8): the engine re-runs the stage, never the stage itself.
# Produces: state/artifacts/design.md with embedded ```scope fenced block
#
# Lifecycle:
#   design_stage_run         — derive paths, delegate to _design_stage_run_inner
#   _design_stage_run_inner  — one route_to_model call writes the working copy;
#                              a copy that passes design's checks becomes design.md
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

# _design_write_outcome <artifact_dir> <outcome> <reason> [findings_json] [design]
# Writes design-verdict.json (#2366: one outcome from the engine's list).
# Called on every terminal exit path so the sidecar is always on disk. #2369:
# what design's checks still find is carried as numbered findings. [design] is
# the passing design it reports on (default: design.md).
_design_write_outcome() {
    local dir="$1" outcome="$2" reason="$3" findings="${4:-[]}" design="${5:-$1/design.md}"
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
    # Only a passing design is reported: on any other outcome design.md is the
    # last good design, not this run's.
    local _wiring="[]"
    if [[ "$outcome" == pass && -s "$design" ]] && declare -F acceptance_list_wiring >/dev/null 2>&1; then
        # Captured first: under pipefail a failing lister would otherwise append
        # a second '[]' to jq's and leave invalid JSON. `WIRING: none` is no file.
        local _wl; _wl="$(acceptance_list_wiring "$design" 2>/dev/null || true)"
        _wiring="$(jq -Rnc '[inputs | select(length > 0 and . != "none")] | unique' <<< "$_wl" 2>/dev/null || true)"
        [[ -n "$_wiring" ]] || _wiring="[]"
    fi
    # #1874: and the files it scoped the change to — so the engine's one scope
    # list is the one build works to, not plan's alone.
    local _scope="[]"
    if [[ "$outcome" == pass && -s "$design" ]] && declare -F acceptance_list_scope >/dev/null 2>&1; then
        local _sl; _sl="$(acceptance_list_scope "$design" 2>/dev/null || true)"
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

    # The result of design's last run stays on disk: it is what tells this
    # run's prompt (under Previous work) why the last try was rejected. Every
    # exit path after the model call replaces it.

    # ADR-068 §8: the model writes a working copy; design.md is replaced only by
    # a design that passes design's checks, so it is always the last good one.
    # A working copy still on disk is a try that did not pass. Otherwise the
    # working copy starts as the last good design, so a design is on disk from
    # the first turn.
    local output_draft="$artifact_dir/design-draft.md" _draft_rejected=0
    if [[ -s "$output_draft" ]]; then
        _draft_rejected=1
    elif [[ -s "$output_design_md" ]]; then
        cp "$output_design_md" "$output_draft" 2>/dev/null || true
    fi

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
    local _framing="Your job: write the design — the change's decisions, its acceptance contract and its scope — in the working copy at the path below. When it passes design's checks it becomes design.md. Save it as you go: a design on disk when your time runs out still counts."
    local _start
    if (( _draft_rejected )); then
        _start="The working copy holds your last try, which was rejected: Previous work says why. Fix what it names. If YOUR LATEST DESIGN below is closer to right, start from that instead."
    elif [[ -s "$output_draft" ]]; then
        _start="The working copy already holds YOUR LATEST DESIGN (below). Change only what needs to change."
    else
        _start="There is no design yet. Write a first version in your first few turns, then improve it."
    fi
    local _triage="Previous work may hold findings from later stages. A finding is yours only if changing the design would fix it: its acceptance contract or its scope. Answer each of those in the design. Leave the others — a bug in the code, a test that does not run, a lint failure — and do not investigate them. In a Findings section of the design, list every finding: what you changed for it, or why you left it. You do not debug code or work out why a test fails."

    cat > "$prompt_input_file" <<DESIGN_PROMPT
## What you own
${_framing}

${_start}

${_triage}

Write the design document to this EXACT absolute path:
  $output_draft

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
block may be as long as completeness requires).

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

    # #2308: the limits close the stage's own text.
    local _dp_limits
    _dp_limits="$(cat <<DESIGN_LIMITS

## What you must not do
- Do not write any file other than the working copy above and your notes file.
  Do not change the code: the design says what changes, it does not make the
  change.
- Do not write the design anywhere else (./design.md, design.md): it is read
  from the absolute path above only.
DESIGN_LIMITS
)"

    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier; tier="$(resolve_tier design "$_DESIGN_DIR")" || return 1

    # ADR-067 §8: design's three parts and the engine's blocks — the
    # repository's guidance for design, its budget and notes file — in the one
    # prompt order.
    local _dp_composed
    if ! _dp_composed="$(stage_prompt_compose_parts "$(cat "$prompt_input_file")
${_dp_limits}")"; then
        error "_design_stage_run_inner: the prompt could not be composed — the engine's blocks are missing"
        _design_write_outcome "$artifact_dir" "broken" "prompt_not_composed"
        return 1
    fi
    printf '%s\n' "$_dp_composed" > "$prompt_input_file"

    # ADR-068 §8: ONE model call per run. A repeat inside the stage starts from
    # the same prompt and learns nothing; the engine re-runs the stage instead
    # (the template's retry:), and that run is handed this one's result and the
    # last good design. A valid design counts when the call ended normally, or
    # when this call wrote it before it was cut off.
    local router_rc=0 _draft_before _draft_after
    _draft_before="$(cksum 2>/dev/null < "$output_draft" || printf 'absent')"
    route_to_model "$tier" "$_dp_composed" >/dev/null || router_rc=$?
    if [[ $router_rc -eq 130 ]]; then
        warn "_design_stage_run_inner: the model call was interrupted (SIGINT) — propagating abort"
        return 130
    fi

    # ADR-018 Pattern 2 (#817): a model that wrote design.md to the repo root
    # despite the path in the prompt, and nothing to the working copy.
    # Untracked → moved into the working copy; tracked → operator-owned, refused.
    local _stray="$repo_root/design.md"
    _draft_after="$(cksum 2>/dev/null < "$output_draft" || printf 'absent')"
    if [[ -f "$_stray" && "$_draft_after" == "$_draft_before" ]]; then
        if git -C "$repo_root" ls-files --error-unmatch "design.md" >/dev/null 2>&1; then
            error "_design_stage_run_inner: tracked design.md at repo root; refusing to relocate (operator-owned)"
            _design_write_outcome "$artifact_dir" "unusable" "stray_conflict"
            stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                "design.md was written to the repo root, where a tracked file already lives" \
                "The model ignored the destination path in the prompt. The root design.md is git-tracked and operator-owned, so it is left untouched."
            emit_event "design.stray.conflict" "plugin=design" "path=$_stray" "reason=tracked"
            return 1
        fi
        if mv "$_stray" "$output_draft" 2>/dev/null; then
            warn "_design_stage_run_inner: recovered design.md from repo root → $output_draft"
            emit_event "design.stray.recovered" "plugin=design" "from=$_stray" "to=$output_draft"
        fi
    fi

    _draft_after="$(cksum 2>/dev/null < "$output_draft" || printf 'absent')"
    if [[ ! -s "$output_draft" ]] || { [[ $router_rc -ne 0 ]] && [[ "$_draft_after" == "$_draft_before" ]]; }; then
        # A working copy that is still only the copy of design.md made above is
        # no try of this run's: it goes, so the next run does not take it for a
        # rejected one.
        if [[ -s "$output_design_md" ]] && cmp -s "$output_draft" "$output_design_md"; then
            rm -f "$output_draft"
        fi
        _design_no_design "$artifact_dir" "$router_rc" "$output_design_md"
        return 1
    fi

    # #825: the run log shows the design this call wrote, not the model's
    # stdout summary ("Design document written to...").
    _design_show "$output_draft"

    # #2369: design checks the working copy — by script, then, when the issue
    # has numbered requirements, by a second model call that asks whether the
    # SPECs cover them.
    local -a _fnd=()
    local _v _u
    _design_checks "$output_draft" "$repo_root" "$_req_f"
    for _v in "${_DESIGN_VIOLATIONS[@]}"; do _fnd+=("$(_dck_plain "$_v")"); done
    if [[ -n "$_reqs" ]] && extract_acceptance_block "$output_draft" >/dev/null 2>&1; then
        _design_coverage "$output_draft" "$_reqs" "$tier"
        if [[ -n "$_DESIGN_COV_OUTCOME" ]]; then
            error "_design_stage_run_inner: the coverage check could not be run ($_DESIGN_COV_OUTCOME)"
            _design_write_outcome "$artifact_dir" "$_DESIGN_COV_OUTCOME" "coverage_check_failed"
            stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                "the check that the design covers the issue could not be run ($_DESIGN_COV_OUTCOME)" \
                "The new design is kept as the working copy, unchecked; design.md is unchanged."
            emit_event "plugin.result" "outcome=$_DESIGN_COV_OUTCOME" "plugin=design" "reason=coverage_check_failed"
            return 1
        fi
        for _u in "${_DESIGN_UNCOVERED[@]}"; do _fnd+=("The issue asks for this and no SPEC covers it: $_u"); done
    fi

    # A design that fails its checks cannot be used: `unusable`, so the engine
    # runs design again, handing it this result. design.md stays the last good
    # design; this try stays as the working copy, for the next run to fix.
    if [[ ${#_fnd[@]} -gt 0 ]]; then
        emit_event "design.checks.failed" "plugin=design" "findings=${#_fnd[@]}"
        local _fj; _fj="$(printf '%s\n' "${_fnd[@]}" | stage_findings_json)"
        _design_write_outcome "$artifact_dir" "unusable" "the design fails ${#_fnd[@]} of its checks" "${_fj:-[]}"
        stage_summary_write "$artifact_dir/design-summary.md" "design" "fail" \
            "the design fails ${#_fnd[@]} check(s)" \
            "$(printf -- '- %s\n' "${_fnd[@]}"; printf '\nThis try is kept as the working copy for the next run; design.md is unchanged.')"
        emit_event "plugin.result" "outcome=unusable" "plugin=design" "reason=checks_failed"
        return 1
    fi

    # The design passes: it becomes design.md, and the working copy is cleared.
    # v2 result contract (#1834): the result is on disk before design.md is.
    _design_write_outcome "$artifact_dir" "pass" "design_produced" "[]" "$output_draft"
    if ! atomic_write "$output_design_md" < "$output_draft"; then
        error "_design_stage_run_inner: could not write $output_design_md"
        _design_write_outcome "$artifact_dir" "broken" "design_unwritable"
        return 1
    fi
    rm -f "$output_draft"

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

# _design_show <design> — one block of the stage's log holding the design the
# call wrote (stage-io trims it for the terminal). Best-effort: the log never
# changes the stage's fate.
_design_show() {
    local _st="${ZBUILD_CURRENT_STAGE:-design}"
    declare -F stage_io_begin >/dev/null 2>&1 || return 0
    stage_io_begin --stage "$_st" --kind computed \
        --input "the design this call wrote: $1" >/dev/null 2>&1 || return 0
    stage_io_end --stage "$_st" --kind computed --seq "${_STAGE_IO_LAST_SEQ:-}" \
        --output "$(cat "$1" 2>/dev/null)" >/dev/null 2>&1 || true
}

# _design_no_design <artifact_dir> <router_rc> <design_md> — the model call
# left no design to check. The call's rc says why (shared mapping, #2225);
# a call that ended normally and wrote nothing is `unusable`. design.md is
# untouched: it stays the last good design.
_design_no_design() {
    local artifact_dir="$1" rc="$2" design_md="$3" _rv="" _rr="" disp="unusable" reason="missing_design_md" head
    if [[ "$rc" -ne 0 ]]; then
        _router_rc_classify "$rc" _rv _rr
        reason="${_rr:-router_rc_nonzero}"
        disp="$(router_reason_disposition "$reason")"
        [[ -n "$disp" ]] || disp="unavailable"
    fi
    case "$disp" in
        timed_out)    head="Design ran out of time before writing a design." ;;
        out_of_turns) head="Design ran out of turns before writing a design." ;;
        rate_limited) head="the model call was rate-limited" ;;
        *)            head="no design was written ($reason)" ;;
    esac
    error "_design_stage_run_inner: $head"
    _design_write_outcome "$artifact_dir" "$disp" "$reason"
    stage_summary_write "$artifact_dir/design-summary.md" "design" "error" "$head" \
        "$(if [[ -s "$design_md" ]]; then printf 'design.md is unchanged: it stays the last good design.'; else printf 'There is no design yet.'; fi)"
    emit_event "plugin.result" "outcome=$disp" "plugin=design" "reason=$reason" "rc=$rc"
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
