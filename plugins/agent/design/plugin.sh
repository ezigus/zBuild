#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/design — Design stage agent (issue #754)                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: design (ADR-013 T2, single-file artifact). One model call per run
# (ADR-068 §8): the engine re-runs the stage, never the stage itself.
# Produces: state/artifacts/design.md — its decisions and acceptance contract;
# it names no files (#2508, ADR-069 §11)
#
# Lifecycle:
#   design_stage_run         — derive paths, delegate to _design_stage_run_inner
#   _design_stage_run_inner  — one route_to_model call writes the working copy;
#                              a copy that passes design's checks becomes design.md
#   design_stage_cleanup     — no-op (the engine brackets the hook, #1705)
#
# legacy-citation: pipeline-stages-intake.sh:1004 (stage_design function)

[[ -n "${_ZBUILD_DESIGN_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
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
# shellcheck source=./lib/summary.sh
source "$_DESIGN_DIR/lib/summary.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_DESIGN_ROOT/scripts/lib/earlier-output.sh"

# _design_write_outcome <artifact_dir> <outcome> <reason> [findings_json] [design]
# Writes design-verdict.json (#2366: one outcome from the engine's list).
# Called on every terminal exit path so the sidecar is always on disk. #2369:
# what design's checks still find is carried as numbered findings. [design] is
# the passing design it reports on (default: design.md).
# design's ANSWER lines from its last call (#2464), kept in its result.
_DESIGN_ANSWERS=()
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
    # #2464 (ADR-068 §6): what design did about each finding it received.
    local _ans="[]"
    [[ ${#_DESIGN_ANSWERS[@]} -gt 0 ]] \
        && _ans="$(printf '%s\n' "${_DESIGN_ANSWERS[@]}" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || printf '[]')"
    local _data
    _data="$(jq -nc --arg at "$_at" --arg sha "$_sha" \
        --argjson w "${_wiring:-[]}" --argjson f "$findings" --argjson a "${_ans:-[]}" \
        --argjson fs "${_ZB_ANS_SHOWN:-0}" --arg un "${_ZB_ANS_MISSING:-}" \
        '{authored_at: $at, authored_at_commit: $sha, wiring_files: $w}
         + (if ($f | length) > 0 then {findings: $f} else {} end)
         + (if ($a | length) > 0 then {answers: $a} else {} end)
         + {findings_shown: $fs}
         + (if $un != "" then {unanswered: ($un | split("\n"))} else {} end)')"
    stage_result_write "$dir/design-verdict.json" "$outcome" "$reason" "$_data" 2>/dev/null \
        || warn "_design_write_outcome: failed to write design-verdict.json (outcome=$outcome)"
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

    # #2364: the scope manifest, found by what it contains among every earlier
    # output (ADR-055 §1). #2445: there is no plan stage; design writes the steps.
    local scope_manifest
    scope_manifest="$(earlier_scope_manifest "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    _design_stage_run_inner \
        "$scope_manifest" \
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

# _design_one_line_specs_v <var> <design_text> — "- <id>" for each [code] or
# [done] SPEC of the design's acceptance block written on one line, with no
# parts under it (#2470). Read by the shell: the design is already in hand.
_design_one_line_specs_v() {
    local -n _dol="$1"; local _dol_l _dol_in=0 _dol_id="" _dol_re="^(${_ACCEPTANCE_ID_ERE})\\[(code|change|done|guard)\\]:"
    _dol=""
    while IFS= read -r _dol_l; do
        if (( ! _dol_in )); then [[ "$_dol_l" == '```acceptance'* ]] && _dol_in=1; continue; fi
        [[ "$_dol_l" == '```'* ]] && break
        [[ -n "$_dol_id" && "$_dol_l" =~ ^[[:space:]]+(Given|When|Then|And|Cleanup): ]] && { _dol_id=""; continue; }
        [[ -n "$_dol_id" ]] && _dol+="- $_dol_id"$'\n'
        _dol_id=""
        [[ "$_dol_l" =~ $_dol_re ]] && _dol_id="${BASH_REMATCH[1]}"
    done <<< "$2"
    [[ -n "$_dol_id" ]] && _dol+="- $_dol_id"$'\n'
    return 0
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = output_design_md path
#   $3 = artifact_dir
_design_stage_run_inner() {
    local scope_manifest="$1"
    local output_design_md="$2"
    local artifact_dir="${3:-$(dirname "$output_design_md")}"

    if [[ -z "$scope_manifest" || -z "$output_design_md" ]]; then
        error "_design_stage_run_inner: requires <scope_manifest> <output_design_md> [artifact_dir]"
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

    local prompt_input_file="$artifact_dir/design-prompt.txt"

    # The persona (ADR-051) reaches the model through the provider, not this
    # text: the stage writes only its own job.
    local _framing="Your job: write the design — the change's decisions and its acceptance contract — in the working copy at the path below. When it passes design's checks it becomes design.md. Save it as you go: a design on disk when your time runs out still counts."
    local _start
    if (( _draft_rejected )); then
        _start="The working copy holds your last try, which was rejected: Previous work says why. Fix what it names. If YOUR LATEST DESIGN below is closer to right, start from that instead."
    elif [[ -s "$output_draft" ]]; then
        _start="The working copy already holds YOUR LATEST DESIGN (below). Change only what needs to change."
    else
        _start="There is no design yet. Write a first version in your first few turns, then improve it."
    fi
    local _triage="Previous work may hold findings from later stages. A finding is yours only if changing the design would fix it: its acceptance contract. Answer each of those in the design. Leave the others — a bug in the code, a test that does not run, a lint failure — and do not investigate them. In a Findings section of the design, list every finding: what you changed for it, or why you left it. You do not debug code or work out why a test fails."

    cat > "$prompt_input_file" <<DESIGN_PROMPT
## What you own
${_framing}

${_start}

${_triage}

Write the design document to this EXACT absolute path:
  $output_draft

The design document MUST include:
1. A brief architectural decision summary (goal, context, decision).
2. A \`\`\`steps block: the ordered work items that deliver the change, one per
   line, each with the areas of the code it is about:
\`\`\`steps
- <what to do, in one sentence> | areas: path/to/file1, path/to/file2
\`\`\`
   The build follows them in order.

3. A \`\`\`acceptance block listing what this change must deliver. Each line is
   one requirement: an id, a status, and ONE behaviour someone could observe and test.
   The id describes the SPEC. Every SPEC id starts with ${_DCK_ID_PREFIX}, then a code of 3 or 4
   capital letters or digits, starting with a letter, that says what it is about,
   a dash, and a number — ${_DCK_ID_PREFIX}LOOP-1 for a SPEC about loop state. SPECs about the
   same thing share the code and count up: ${_DCK_ID_PREFIX}LOOP-1, ${_DCK_ID_PREFIX}LOOP-2. An id is never one
   the issue itself writes.
   An id never changes: a SPEC you keep keeps its id. A new SPEC takes the
   number one more than the highest its code has ever had, removed ones counted.
   A SPEC you drop gets its own line in the block, \`REMOVED: <id> — <why>\`, and
   that line stays in every later design, so the id is never used again.
   A design written with the old ids (SPEC-1, or ids that do not start with
   ${_DCK_ID_PREFIX}) gives each SPEC a new id once; the old ids need no REMOVED line.
   A requirement that asks for several things gets one SPEC per thing, each
   naming the same requirement id in covers: — never one SPEC that joins them with "and" or ";".
   Each SPEC is checked against one assertion, so a SPEC that promises two
   things is never fully met by it.

   Under its line, each [code] and [done] SPEC says its behaviour in parts, one
   per line, indented ([no-code] may too):
   - \`Given:\` the setup the behaviour starts from. Optional; any number.
   - \`When:\` the one action — exactly one When per SPEC: a second action is a second SPEC.
   - \`Then:\` something a test can observe after the When — an output, a
     result, a file the code writes, an event. One or more. Never what a file
     or a test contains.
   - \`And:\` adds another line to the Given, Then or Cleanup above it.
   - \`Cleanup:\` what must be true again after the test, for anything the
     Given sets up or a Then says happens that outlives the test — an exported
     variable, a file outside the test's own folder, global config or git state.
     Leave it out when nothing outlives the test: the test harness cleans up
     after every test.

   The status says what work the requirement needs. Look at the code before you choose:
   - \`${_DCK_ID_PREFIX}LOOP-1[code]:\` — it needs code. Its test must fail on the code as it is before your change, and pass after it.
     If the code already does it, it is not [code]: its test would already pass, and the build stalls on it.
     Every requirement, whatever its status, describes what someone could see happen, not what a file contains: not "x.sh contains foo", "file y exists" or "the test file has both cases" — no test can prove those.
   - \`${_DCK_ID_PREFIX}LOOP-2[no-code]:\` — it needs work that changes no behaviour: docs, a
     test, config, or a refactor. Its test must pass after the change; it need not fail before.
   - \`${_DCK_ID_PREFIX}GARD-1[done]:\` — the code from before your change already does it. Name the evidence at the end of the line, after \` evidence: \` —
     a file by its path from the repository root, then \` | \`, then one line of it copied as it is
     (scripts/x.sh | run_guard()), or an existing test file named alone.
     The text must be in the file on the commit this branch started from: code this work added is not
     done yet, so it is [code]. A [done] SPEC still gets a test: it must pass after the change, and it
     need not fail before — it proves the finished change still does what the old code did.
   Every requirement carries one of the three. A change that edits code needs at least one [code] requirement.

   You name no files: no test file, and no list of the files the change
   touches. The tests are written after the design, in the repository's test
   folders, wherever they belong. Each assertion's label carries its
   requirement's tag, which includes this issue's number — for
   ${_DCK_ID_PREFIX}LOOP-1 of this issue:
   $(acceptance_spec_tag ${_DCK_ID_PREFIX}LOOP-1 2>/dev/null || printf '[%sLOOP-1]' "$_DCK_ID_PREFIX") — and that tag is how a requirement's test is
   found. Each [code] assertion is also run against the code from before your
   change and must fail there, so write ONE requirement per assertion — then
   each behaviour is checked on its own.

The \`\`\`acceptance block format:
\`\`\`acceptance
${_DCK_ID_PREFIX}LOOP-1[code]: <one new behaviour this change introduces>
  Given: <the setup it starts from>
  When: <the one action>
  Then: <what a test can observe after it>
  And: <another thing a test can observe>
  Cleanup: <what must be true again after, when the setup or a Then outlives the test>
${_DCK_ID_PREFIX}LOOP-2[no-code]: <docs, a test, config or a refactor that changes no behaviour>
${_DCK_ID_PREFIX}GARD-1[done]: <something the code already does> evidence: scripts/x.sh | run_guard()
  When: <the action>
  Then: <what the code from before this change already does>
REMOVED: ${_DCK_ID_PREFIX}LOOP-3 — <why this SPEC was dropped>
WIRING: <the existing file that calls the new code>
\`\`\`

WIRING: Which existing file calls the new code?
- Name the existing file whose code calls (or loads) the new behaviour:
  the place a running program reaches it from. It is not the file that
  implements the behaviour, and it is not a test. If that file were put back
  to how it is today, at least one test of this change would fail.
- A list, schema or config entry is never this file: adding a name to an event
  list, a schema or a config list changes no behaviour on its own.
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

A requirement you do not understand — the issue could mean either of two
things — is not guessed in silence. Write one line for it in the design,
outside the fenced blocks:
UNCLEAR: <id> | <the question> | <what you assumed>
where <id> is the requirement's id. Then carry on with that assumption: design
the change as if it were the answer. The question and your assumption are
shown to the people who can answer it.

Keep the prose focused and under 200 lines (the acceptance block may be as
long as completeness requires).

## What you judge against
The issue may describe a solution as well as the
problem. A section that records a decision (for example "Decision:") is binding: follow it.
Anything else it proposes — an approach, a file list, a claim that
some files or tests are unaffected — is a starting point, not the answer: check
it against the code yourself and come up with your own design. Where yours
differs, say why.

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
    # #2482 (ADR-069 §2): the code a [done] claim is checked on, as the judges
    # are shown it (ADR-072 §2). On #1805 run 42293991602 design had only the
    # working copy and took code this branch added for the code from before.
    # Read once a run of this stage: the coverage check reads the same copy
    # (_DESIGN_BASE_DIR, set when this has run).
    local _base_dir=""
    judge_base_dir_v _base_dir "${ZBUILD_REPO_ROOT:-$PWD}" 2>/dev/null || _base_dir=""
    local _DESIGN_BASE_DIR="$_base_dir"
    [[ -n "$_base_dir" ]] && printf '\n### The code from before this change\nThe commit this branch started from is a copy at %s. A [done] SPEC is checked\nthere: to see whether the code from before your change already does something,\nopen the file there, not in the working copy — the working copy holds every\nchange this branch made, in this round and in earlier ones.\n' "$_base_dir" >> "$prompt_input_file"
    [[ -n "$_reqs" ]] && printf '\n### Requirements from the issue (each with its id)\n%s\n\nEvery requirement above must be covered by at least one SPEC. End each SPEC line with ` covers: ` and the ids of the requirements it covers, before any ` evidence: ` — for example `'"${_DCK_ID_PREFIX}"'LOOP-1[code]: <behaviour> covers: <requirement ids>`. A requirement the code already meets is covered by a [done] SPEC with evidence.\n' "$_reqs" >> "$prompt_input_file"

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
        # #2470 (ADR-073 §1): the SPECs it keeps that still need their parts,
        # named before design writes, not learned from a failed check.
        local _one_line=""
        _design_one_line_specs_v _one_line "$_prior_design_body"
        [[ -n "$_one_line" ]] && printf '\nThese [code] and [done] SPECs of YOUR LATEST DESIGN are still written on one line. Each one you keep is rewritten with its parts on the lines under it — Given, When, Then, And, Cleanup:\n%s' "$_one_line" >> "$prompt_input_file"
        printf '\nRefine YOUR LATEST DESIGN.\n' \
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
        printf '\nIf Previous work says a [code] requirement'"'"'s test already passes on the code from before this change, rewrite that requirement so its test fails on the old code and passes after — or, if the code already does it, mark it [done] and name the evidence (a file and one of its lines, or an existing test file) after " evidence: ". The evidence is checked. The tests cannot be changed later in this run, so this is where it is fixed. Check the other acceptance entries against the feedback too, and fix any it shows is wrong.\n' \
            >> "$prompt_input_file"
    fi

    # #2464 (ADR-072 §5, ADR-068 §6): a finding of design's own check that
    # design says is wrong is answered, not designed around; the check judges
    # it again with the answer.
    printf '\nIf a finding of your design'"'"'s own check (under Previous work, as design finding <n>) is wrong, do not change the design for it: answer it on its own line in your reply, ANSWER design finding <n>: wrong — <why>. The check judges it again, with your answer.\n' \
        >> "$prompt_input_file"

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
    local router_rc=0 _draft_before _draft_after _dp_reply=""
    _draft_before="$(cksum 2>/dev/null < "$output_draft" || printf 'absent')"
    # #2464: the reply is kept for its ANSWER lines, through a file — the call
    # stays in this shell, as before (no $( ), ADR-065 §5).
    local _dp_reply_f="${ZBUILD_STAGE_SCRATCH:-$artifact_dir}/design-reply.txt"
    route_to_model "$tier" "$_dp_composed" > "$_dp_reply_f" || router_rc=$?
    [[ -f "$_dp_reply_f" ]] && { IFS= read -r -d '' _dp_reply < "$_dp_reply_f" || true; }
    # ADR-068 §6: a finding it was shown and did not answer stays open.
    _DESIGN_ANSWERS=()
    zb_answers_finish _DESIGN_ANSWERS "$_dp_composed" "$_dp_reply"
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
        if ! mv "$_stray" "$output_draft" 2>/dev/null; then
            # Checking the unchanged working copy would pass the last good design
            # off as this call's (review on PR #2399).
            error "_design_stage_run_inner: could not move the stray design.md from the repo root into $output_draft"
            _design_write_outcome "$artifact_dir" "unusable" "stray_not_moved"
            stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                "design.md was written to the repo root and could not be moved into place" \
                "The model ignored the destination path in the prompt. The root design.md is left where it is; design.md is unchanged."
            emit_event "plugin.result" "outcome=unusable" "plugin=design" "reason=stray_not_moved"
            return 1
        fi
        warn "_design_stage_run_inner: recovered design.md from repo root → $output_draft"
        emit_event "design.stray.recovered" "plugin=design" "from=$_stray" "to=$output_draft"
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
    # has numbered requirements and the scripted checks pass, by a second model
    # call that asks whether the SPECs cover them. A design that already fails
    # is not sent to it: a coverage call that could not run would hide the
    # findings the next run needs (review on PR #2399).
    local -a _fnd=()
    local _v _u
    # #2462: held to the ids of the last design that passed (and, through the
    # requirement list, to the ids the issue's words write).
    _design_checks "$output_draft" "$repo_root" "$_req_f" "$output_design_md"
    for _v in "${_DESIGN_VIOLATIONS[@]}"; do _fnd+=("$(_dck_plain "$_v")"); done
    if [[ ${#_fnd[@]} -eq 0 && -n "$_reqs" ]] && extract_acceptance_block "$output_draft" >/dev/null 2>&1; then
        local _dp_ans="" _a
        for _a in ${_DESIGN_ANSWERS[@]+"${_DESIGN_ANSWERS[@]}"}; do
            [[ "$_a" == "design finding "* ]] && _dp_ans+="$_a"$'\n'
        done
        _design_coverage "$output_draft" "$_reqs" "$tier" "$_dp_ans"
        if [[ -n "$_DESIGN_COV_OUTCOME" ]]; then
            error "_design_stage_run_inner: the coverage check could not be run ($_DESIGN_COV_OUTCOME)"
            _design_write_outcome "$artifact_dir" "$_DESIGN_COV_OUTCOME" "coverage_check_failed"
            stage_summary_write "$artifact_dir/design-summary.md" "design" "error" \
                "the check that the design covers the issue could not be run ($_DESIGN_COV_OUTCOME)" \
                "The new design is kept as the working copy, unchecked; design.md is unchanged."
            emit_event "plugin.result" "outcome=$_DESIGN_COV_OUTCOME" "plugin=design" "reason=coverage_check_failed"
            return 1
        fi
        while IFS= read -r _u; do [[ -n "$_u" ]] && _fnd+=("$_u"); done < <(_design_coverage_findings)
    fi

    # A design that fails its checks cannot be used: `unusable`, so the engine
    # runs design again, handing it this result. design.md stays the last good
    # design; this try stays as the working copy, for the next run to fix.
    if [[ ${#_fnd[@]} -gt 0 ]]; then
        emit_event "design.checks.failed" "plugin=design" "findings=${#_fnd[@]}"
        local _fj; _fj="$(printf '%s\n' "${_fnd[@]}" | stage_findings_json)"
        _design_write_outcome "$artifact_dir" "unusable" "the design fails ${#_fnd[@]} of its checks" "${_fj:-[]}"
        # #2470 (ADR-055 §9): the findings are in the result, shown once; the
        # summary says where they are, never copies them.
        local _fsa=""; zb_answers_summary_v _fsa _DESIGN_ANSWERS
        stage_summary_write "$artifact_dir/design-summary.md" "design" "fail" \
            "the design fails ${#_fnd[@]} check(s)" \
            "The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged."$'\n'"$_fsa"
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
    # #2445: the design's work steps, as the file every reader finds as the
    # work plan (a `steps` list, earlier_work_plan).
    _design_write_steps "$output_design_md" "$artifact_dir/design-steps.json"

    # ADR-055 §9: the SPECs a later stage is held to, and the boundary it may
    # touch; #2476: by name, each with what it covers.
    _design_pass_summary_write "$artifact_dir" "$output_design_md"
    emit_event "plugin.result" "stage=design" \
        "plugin=design" \
        "artifact=design.md"

    return 0
}

# _design_write_steps <design_md> <out_json> — the ```steps block as
# {title, steps:[{id, description, areas, topic}]}. A design with no steps writes none
# (and removes an earlier one, so a stale list is never read as this design's).
# #2458 (ADR-071): each step's topic comes from its files — `tests` when they are
# in the repository's test folders, which only the stage that writes the tests
# may change (#2508); `change` otherwise. A step with both is split, so each part
# reaches the stage that may do it.
_design_write_steps() {
    local design="$1" out="$2" line in_block=0 title tfs
    local -a lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^'```steps'[[:space:]]*$ ]]; then in_block=1; continue; fi
        if [[ $in_block -eq 1 && "$line" =~ ^'```'[[:space:]]*$ ]]; then break; fi
        [[ $in_block -eq 1 ]] || continue
        if [[ "$line" =~ ^[[:space:]]*[-*0-9.]+[[:space:]]+(.*[^[:space:]]) ]]; then
            lines+=("${BASH_REMATCH[1]}")
        elif [[ -n "${line// }" && ${#lines[@]} -gt 0 ]]; then
            # #2460: a step whose words or areas carry on to the next line.
            local _c="${line#"${line%%[![:space:]]*}"}"
            lines[-1]+=" ${_c%"${_c##*[![:space:]]}"}"
        fi
    done < "$design"
    if [[ ${#lines[@]} -eq 0 ]]; then rm -f "$out" 2>/dev/null; return 0; fi
    title="$(grep -m1 -E '^# ' "$design" 2>/dev/null || true)"; title="${title#\# }"
    # #2508 (ADR-071): an area in the test folders is the test author's.
    local _l _a _ar; tfs=""
    for _l in "${lines[@]}"; do
        [[ "$_l" == *" | areas:"* ]] || continue
        IFS=',' read -ra _ar <<< "${_l#* | areas:}"
        for _a in ${_ar[@]+"${_ar[@]}"}; do
            _a="${_a#"${_a%%[![:space:]]*}"}"; _a="${_a%"${_a##*[![:space:]]}"}"
            [[ -n "$_a" ]] && zb_is_test_path "$_a" && tfs+="$_a"$'\n'
        done
    done
    tfs="$(jq -Rsc 'split("\n") | map(select(length > 0))' <<< "$tfs" 2>/dev/null)"
    [[ -n "$tfs" ]] || tfs='[]'
    printf '%s\n' "${lines[@]}" | jq -Rsc --arg t "$title" --argjson tf "$tfs" '
        split("\n") | map(select(length > 0))
        | [.[] | split(" | areas:") as $p
            | {d: ($p[0] | gsub("^\\s+|\\s+$"; "")),
               a: (($p[1] // "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}
            | ([.a[] | select(. as $f | $tf | index([$f]))]) as $ta
            | ([.a[] | select(. as $f | $tf | index([$f]) | not)]) as $ca
            | if ($ta | length) > 0 and ($ca | length) > 0
                then {description: .d, areas: $ca, topic: "change"}, {description: .d, areas: $ta, topic: "tests"}
              elif ($ta | length) > 0 then {description: .d, areas: $ta, topic: "tests"}
              else {description: .d, areas: $ca, topic: "change"} end]
        | {title: $t, steps: [to_entries[] | {id: "step-\(.key + 1)"} + .value]}' \
        | atomic_write "$out" || rm -f "$out" 2>/dev/null
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

# ─── cleanup ────────────────────────────────────────────────────────────────
