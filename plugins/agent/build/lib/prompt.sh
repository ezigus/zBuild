#!/usr/bin/env bash
# plugins/agent/build/lib/prompt.sh — prompt composition helpers for the build stage.
# Sourced by plugin.sh after shared libs (prompt-overrides.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_PROMPT_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_PROMPT_LOADED=1

# _build_render_task_header <iter> <max_iter>
# Emits the stable banner that prefixes every build prompt.
_build_render_task_header() {
    local iter="${1:-1}"
    local max_iter="${2:-1}"
    printf '============== ZBUILD BUILD — iter %s/%s ==============\n' \
        "$iter" "$max_iter"
}

# _build_compose_instructions <plan_files_csv>
# Emits the INSTRUCTIONS section of the framed prompt — stable scope/loop/
# sentinel/rules text, identical across iterations.
_build_compose_instructions() {
    local plan_files_csv="${1:-}"
    local scope_section=""
    if [[ -n "$plan_files_csv" ]]; then
        scope_section="$(printf '%s\n' "$plan_files_csv" | tr ',' '\n' | sed 's/^/  - /')"
    else
        scope_section="  (no plan.files[] declared — refuse to edit if scope is unclear)"
    fi
    # Persona seam (#1391): open with the developer persona's framing when its
    # manifest is present; falls back to $_task_intro directly when absent
    # (persona_stage_framing returns 1). Mirrors design/plugin.sh (#1324).
    local _task_intro="You have Read, Edit, Write, and
Bash tools available. Your job is to edit the working tree to implement the
ORIGINAL TASK above."
    local _framing
    # #1576: track whether the persona was applied (for the ZBUILD_STAGE_IO_PERSONA
    # export at the call site). #1570: the fallback is behavior-first ($_task_intro),
    # NOT the old "You are an autonomous build agent" profession sentence.
    _BUILD_PERSONA_APPLIED=0
    if _framing="$(persona_stage_framing developer "$_task_intro" "$_BUILD_ROOT/plugins" 2>/dev/null)"; then
        _BUILD_PERSONA_APPLIED=1
    else
        _framing="$_task_intro"
    fi
    # Guard: rc=0 but empty output (e.g. perspective key absent in manifest).
    [[ -n "$_framing" ]] || { _framing="$_task_intro"; _BUILD_PERSONA_APPLIED=0; }
    cat <<BUILD_PROMPT
${_framing}

### Scope (plan.files[])
You may ONLY touch files listed here. Refuse any out-of-scope edit.
${scope_section}

### How the loop works
- Each iteration you may make code changes via Edit/Write/Bash.
- After each iteration the pipeline captures \`git diff HEAD\` and feeds it
  back to you so you can verify progress.
- Do NOT emit a unified diff in your response — the pipeline derives the
  canonical \`diff.patch\` artifact from \`git diff HEAD\` automatically.

### Completion sentinel
Emit \`LOOP_COMPLETE\` on its own line as the FINAL line of your response
WHEN the implementation is complete — whether you just finished it OR
it was already done before you started. If the branch already contains
the required changes (check \`git log\` for commits + \`git diff\` for any
remaining gap), emit \`LOOP_COMPLETE\` immediately. Do NOT keep iterating
when there is nothing left to do.

### Rules
- Touch only files in the scope list above.
- Do not run \`git commit\` — the pipeline owns commit semantics.
- NEVER run a command that mutates git branch state or the working tree —
  no \`git checkout -b\`/\`switch\`/\`commit\`/\`push\`/\`tag\`/\`reset\`. You are running
  INSIDE the pipeline's own checkout; switching or creating a branch hijacks the
  run. The pipeline owns the branch.
- If you must exercise a command you are building (or any command that could
  publish, tag, push, or otherwise mutate state), run it in \`--dry-run\` mode.
  Do everything you can to verify behavior without side effects.
- Keep changes minimal and aligned with the plan.
- Clean up scratch siblings of the files you edit (\`*.bak\`, \`*.orig\`,
  \`*.rej\`, \`*.head\`, \`*.tmp\`, \`*~\`). \`sed -i.bak\` and
  \`git show HEAD:f > f.head\` both leave one behind — prefer \`sed -i\` with no
  suffix, and delete any comparison scratch before you finish. Out-of-scope
  scratch is removed for you; any OTHER out-of-scope path voids the whole
  iteration, so do not rely on the cleanup.
- If satisfying a gate requires a file outside your scope, do not work around it — emit \`BLOCKED: <gate> requires <file> (out of scope)\` and stop.

### Commit message (#608)
Before the final \`LOOP_COMPLETE\` line, emit a single line of the form:

    COMMIT_SUMMARY: <one-line description of this iteration's change>

Keep it under 72 characters, present tense, imperative mood (e.g.
"add foo parser" not "added"). The pipeline uses this as the git commit
message for the per-iteration commit it creates on your behalf. If you
omit this line the pipeline falls back to the plan title.
BUILD_PROMPT
}

# _build_compose_prompt_body <output_file> <task_header> <plan_payload>
#   <instructions> <design_decisions> <acceptance_testfiles>
#   <acceptance_spec_ids> <review_feedback_body> <acceptance_gap_ids>
#   <feedback_body> <iter_n>
# Assembles the full framed prompt and writes it to <output_file>.
_build_compose_prompt_body() {
    local _prompt_input_file="$1"
    local _task_header="$2"
    local _plan_payload="$3"
    local _instructions="$4"
    local _design_decisions="$5"
    local _acceptance_testfiles="$6"
    local _acceptance_spec_ids="$7"
    local _review_feedback_body="$8"
    local _acceptance_gap_ids="$9"
    local _feedback_body="${10}"
    local _iter_n="${11}"
    # ${12} was _acceptance_tautology_ids — retired in #2022 with the
    # re-author mandate it fed. Build no longer authors assertions.

    {
        printf '%s\n' "$_task_header"
        printf '## ORIGINAL TASK (immutable across iterations)\n'
        printf '%s\n\n' "$_plan_payload"
        printf '## INSTRUCTIONS\n%s\n' "$_instructions"
        if [[ -n "$_design_decisions" ]]; then
            printf '\n## DESIGN DECISIONS (from the design stage — honor these directives; they refine the plan)\n'
            printf '%s\n' "$_design_decisions"
            printf 'Where a design decision above conflicts with the plan, follow the design decision.\n'
        fi
        if [[ -n "$_acceptance_testfiles" ]]; then
            printf '\n## ACCEPTANCE TESTS (you MUST make these pass)\n'
            printf 'You do NOT author or modify acceptance assertions. They were written from the design contract by a separate stage, before your implementation existed, and they are the contract you implement against. A failing assertion means YOUR CODE is wrong — fix the code. You MUST NOT weaken, delete, retag or re-author any assertion, and you must not edit the testfiles listed below; the spawn denies it and a mechanical guard checks it. If you believe an assertion genuinely does not test its SPEC, say so in your output and leave it alone: correcting it is the author stage\047s job, not yours (#2022, ADR-036).\n'
            printf 'Each test MUST contain an assert call whose label includes the [SPEC-n] tag for the SPEC it verifies (e.g. assert_eq "[SPEC-1] ..." exp act). The acceptance-gate (ADR-036) requires every SPEC-n to have a [SPEC-n]-tagged assertion. A CHANGE-behavior SPEC-n MUST have a tagged assertion that FAILS at the merge-base baseline and passes here (a tautological change-SPEC that passes without your implementation is rejected); a GUARD/invariant SPEC-n is tagged but NOT contorted to fail at baseline. See the per-id list below.\n'
            local _at_tf
            while IFS= read -r _at_tf; do
                [[ -n "$_at_tf" ]] && printf -- '- %s\n' "$_at_tf"
            done <<< "$_acceptance_testfiles"
        fi
        if [[ -n "$_acceptance_spec_ids" ]]; then
            printf '\nWhat each SPEC requires:\n'
            local _rq_sid _rq_text _rq_line
            while IFS= read -r _rq_line; do
                [[ -n "$_rq_line" ]] || continue
                [[ "$_rq_line" == *$'\t'* ]] || continue
                _rq_sid="${_rq_line%%$'\t'*}"; _rq_text="${_rq_line#*$'\t'}"
                [[ -n "$_rq_text" ]] && printf -- '- [%s] %s\n' "$_rq_sid" "$_rq_text"
            done <<< "$_acceptance_spec_ids"
        fi
        if [[ -n "$_acceptance_spec_ids" ]]; then
            printf '\n### SPEC IDS YOU MUST COVER (acceptance gate, ADR-036)\n'
            printf 'Every SPEC id below needs at least one assertion whose label carries its [SPEC-n] tag; self-verify the FULL set is tagged before emitting LOOP_COMPLETE. A CHANGE-behavior SPEC (new behavior this change introduces) MUST have a [SPEC-n] assertion that FAILS at the merge-base baseline. A GUARD/invariant SPEC (behavior that must stay unchanged) is tagged but MUST NOT be contorted to fail at baseline.\n'
            # #1978: each line is "SPEC-n<TAB>requirement". Naming the id alone
            # made the demand a SHAPE requirement — "an assertion tagged
            # [SPEC-n] that fails at baseline" — satisfiable by an assertion
            # about any field. A line with no tab is an id whose text could not
            # be resolved; it degrades to the id-only form rather than dropping.
            local _sid _stext _sline
            while IFS= read -r _sline; do
                [[ -n "$_sline" ]] || continue
                _sid="${_sline%%$'\t'*}"
                _stext=""
                [[ "$_sline" == *$'\t'* ]] && _stext="${_sline#*$'\t'}"
                if [[ -n "$_stext" ]]; then
                    printf -- '- [%s] %s\n' "$_sid" "$_stext"
                    printf -- '  → needs a `[%s]`-tagged assertion that tests exactly that (change → fails at baseline; guard → tagged, not contorted)\n' "$_sid"
                else
                    printf -- '- [%s] needs a `[%s]`-tagged assertion (change → fails at baseline; guard → tagged, not contorted)\n' "$_sid" "$_sid"
                fi
            done <<< "$_acceptance_spec_ids"
        fi
        if [[ -n "$_review_feedback_body" ]]; then
            printf '\n## PRIOR REVIEW FEEDBACK (from a prior review iteration)\n'
            printf '%s\n' "$_review_feedback_body"
            printf 'Address the reviewer findings above before emitting LOOP_COMPLETE.\n'
        fi
        if [[ -n "$_acceptance_gap_ids" ]]; then
            printf '\n## ACCEPTANCE COVERAGE GAPS (add [SPEC-n] tags for these)\n'
            printf 'The acceptance gate (ADR-036) found these SPEC ids have NO [SPEC-n]-tagged assertion in the diff. This is AUTHORITATIVE over any review prose on acceptance coverage. Adding a missing [SPEC-n] label to an existing acceptance assertion is REQUIRED and is NOT "weakening" — only changing the asserted values is forbidden:\n'
            local _gap
            while IFS= read -r _gap; do
                [[ -n "$_gap" ]] && printf -- '- [%s] add a `[%s]`-tagged assertion (re-verify it still reflects the real behavior)\n' "$_gap" "$_gap"
            done <<< "$_acceptance_gap_ids"
        fi
        if [[ -n "$_feedback_body" ]]; then
            local _prev_iter=$(( _iter_n - 1 ))
            [[ "$_prev_iter" -lt 1 ]] && _prev_iter=1
            printf '\n## CURRENT ITERATION FEEDBACK (from test_assessment iter %d)\n' \
                "$_prev_iter"
            printf '%s\n' "$_feedback_body"
            printf 'Fix the issues above before emitting LOOP_COMPLETE.\n'
        fi
    } > "$_prompt_input_file"
}
