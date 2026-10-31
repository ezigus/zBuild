#!/usr/bin/env bash
# plugins/agent/build/lib/prompt.sh — prompt composition helpers for the build stage.
# Sourced by plugin.sh after shared libs (prompt-overrides.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_PROMPT_LOADED:-}" ]] && return 0

# _bp_spec_tag <spec_id> — the tag an assertion carries for a SPEC
# (acceptance_spec_tag: [#<issue>/SPEC-n] under an issue). The bare form only if
# the library is somehow not loaded, so the prompt never names no tag at all.
_bp_spec_tag() {
    if declare -F acceptance_spec_tag >/dev/null 2>&1; then acceptance_spec_tag "$1"
    else printf '[%s]' "$1"; fi
}

_ZBUILD_BUILD_PROMPT_LOADED=1

# _build_render_task_header <round>
# Emits the stable banner that prefixes every build prompt: the loop's round.
_build_render_task_header() {
    local round="${1:-1}"
    printf '============== ZBUILD BUILD — round %s ==============\n' "$round"
}

# _build_compose_instructions <plan_files_csv>
# Emits the INSTRUCTIONS section of the framed prompt — stable scope/loop/
# sentinel/rules text, identical across tries.
_build_compose_instructions() {
    : "${1:-}"   # plan files: the scope list is part of the limits (_build_compose_limits)
    # The persona (ADR-051) reaches the model through the provider, not this
    # text: the stage writes only its own job.
    local _framing="Your job is to edit the working tree to implement the ORIGINAL TASK
below. You have Read, Edit, Write, and Bash tools available."
    cat <<BUILD_PROMPT
${_framing}

### How your work is kept
- You make code changes via Edit/Write/Bash. What you change stays in the
  working tree: if you do not finish, the next try continues from it, and your
  notes file (in the rules below) carries what you learned.
- Do NOT emit a unified diff in your response — the pipeline derives the
  canonical \`diff.patch\` artifact from \`git diff HEAD\` automatically.

### Saying you are done
Emit \`LOOP_COMPLETE\` on its own line as the FINAL line of your response
WHEN the implementation is complete — whether you just finished it OR
it was already done before you started. If the branch already contains
the required changes (check \`git log\` for commits + \`git diff\` for any
remaining gap) AND no stage under Previous work has failed findings left to
answer, emit \`LOOP_COMPLETE\` immediately. Do NOT keep iterating when there is
nothing left to do. While a failed stage's findings are open, finishing with
no change needs each of them answered: \`done\` (you changed something for
it), or \`nothing to do\` with the reason.

### When a finding does not reproduce
If a failing stage names a test and that test PASSES when you run it on this
tree, say so and stop. Answer that finding, on its own line before the sentinel:

    ANSWER <stage> finding <n>: nothing to do — not reproduced: <the path you ran>

one line per finding. This is a REPORT, not a verdict: the pipeline re-runs the
stage that raised the finding to check. Do not keep searching for the cause of
a failure you cannot produce, and do not change code to chase one.

### Running tests
- Do NOT run \`npm test\`, the full suite, or \`npm run lint\` — the pipeline
  runs them and their results are under Previous work.
- Start from the test files listed under Previous work, and the requirements
  each covers: they fail on the code as it is now; do not run them to find that
  out. Run a test only after you change the code it checks, and only that test
  file. A command that runs longer than ~2 minutes can cost you the whole call.
- A failed stage under Previous work is red RIGHT NOW on this tree. Start from
  the failing line it quotes.

### Data another part of the code writes
When your change reads data that another part of the code writes — a file, a
record, a field, a message — open the code that writes it and use the names
and shapes it really produces, and when it produces them; never assume them.

### Commit message (#608)
Before the final \`LOOP_COMPLETE\` line, emit a single line of the form:

    COMMIT_SUMMARY: <one-line description of this iteration's change>

Keep it under 72 characters, present tense, imperative mood (e.g.
"add foo parser" not "added"). The pipeline uses this as the git commit
message for the per-iteration commit it creates on your behalf. If you
omit this line the pipeline falls back to the plan title.
BUILD_PROMPT
}

# _build_compose_limits <plan_files_csv>
# What build must not do (#2308): the scope it may touch and its rules. The
# body places it after everything build judges against.
_build_compose_limits() {
    local plan_files_csv="${1:-}" scope_section
    if [[ -n "$plan_files_csv" ]]; then
        scope_section="$(printf '%s\n' "$plan_files_csv" | tr ',' '\n' | sed 's/^/  - /')"
    else
        scope_section="  (no plan.files[] declared — refuse to edit if scope is unclear)"
    fi
    cat <<BUILD_LIMITS
### Scope (plan.files[])
You may ONLY touch files listed here. Refuse any out-of-scope edit.
${scope_section}

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
BUILD_LIMITS
}

# _build_compose_prompt_body <output_file> <task_header> <plan_payload>
#   <instructions> <design_decisions> <acceptance_testfiles>
#   <acceptance_spec_ids> <iter_n> [limits]
# #2308: build's own three parts — what it owns (the instructions), what it
# judges against (the task, the design, the acceptance tests), and what it must
# not do — written to <output_file>. Earlier stages' outputs are not composed
# here: they reach build under the engine's Previous work (ADR-067 §8). The
# task header is not part of the prompt: a banner saying "iter N/M" told the
# model a different thing from the loop it was in.
_build_compose_prompt_body() {
    local _prompt_input_file="$1"
    local _task_header="$2"
    local _plan_payload="$3"
    local _instructions="$4"
    local _design_decisions="$5"
    local _acceptance_testfiles="$6"
    local _acceptance_spec_ids="$7"
    local _iter_n="$8"
    local _limits="${9:-}"
    : "$_task_header" "$_iter_n"

    {
        printf '## What you own\n'
        printf '%s\n\n' "$_instructions"
        printf '## What you judge against\n'
        printf '### ORIGINAL TASK (immutable across iterations)\n'
        printf '%s\n' "$_plan_payload"
        if [[ -n "$_design_decisions" ]]; then
            printf '\n### DESIGN DECISIONS (from the design stage — honor these directives; they refine the plan)\n'
            printf '%s\n' "$_design_decisions"
            printf 'Where a design decision above conflicts with the plan, follow the design decision.\n'
        fi
        if [[ -n "$_acceptance_testfiles" ]]; then
            printf '\n### ACCEPTANCE TESTS (you MUST make these pass)\n'
            # #2269: build can only change code, so it is asked only for that.
            printf 'These tests were written before your code. Make them pass by changing code only. Each requirement below is checked by the assertion labelled with its tag (for SPEC-1 of this issue: %s).\n' "$(_bp_spec_tag SPEC-1)"
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
                [[ -n "$_rq_text" ]] && printf -- '- %s %s\n' "$(_bp_spec_tag "$_rq_sid")" "$_rq_text"
            done <<< "$_acceptance_spec_ids"
        fi
        if [[ -n "$_acceptance_spec_ids" ]]; then
            printf '\n### REQUIREMENTS YOUR CODE MUST MEET\n'
            printf 'Your change is done when the test for every requirement below passes.\n'
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
                    printf -- '- %s %s\n' "$(_bp_spec_tag "$_sid")" "$_stext"
                    printf -- '  → its test is already written; make it pass\n'
                else
                    printf -- '- %s — its test is already written; make it pass\n' "$(_bp_spec_tag "$_sid")"
                fi
            done <<< "$_acceptance_spec_ids"
        fi
        printf '\n## What you must not do\n'
        if [[ -n "$_acceptance_testfiles" ]]; then
            # #2163: a fact about THIS stage's permissions — never a claim about
            # who else does what (ADR-061: stages do not name stages).
            printf 'The acceptance testfiles listed above are read-only for this stage: the engine denies edits to them, and a mechanical check restores any change. They are the contract you implement against, written before your implementation existed. A failing assertion means YOUR CODE is wrong — fix the code. You MUST NOT weaken, delete, retag or re-author any assertion. If you believe an assertion genuinely does not test its SPEC, say so in your output and do not edit it.\n\n'
        fi
        [[ -n "$_limits" ]] && printf '%s\n' "$_limits"
    } > "$_prompt_input_file"
}
