#!/usr/bin/env bash
# tests/unit/notes-earlier-version-test.sh — a stage's own notes and output,
# written for an earlier version of what it was asked (the design, the
# requirements), are marked so in its Previous work (#2575, ADR-068 §8).
#
# Why: #1764 run 44782866204 — build was given its own notes from an earlier
# run, headed "Status: COMPLETE" and "State of key files (all correct)". They
# described the architecture the current design reverses; build spent its
# round-1 try reconciling the two, 42 tool calls, no edits, and a timeout.
#
# V1 [code]  notes written while the design was as it is now are shown as now:
#            no mark
# V2 [code]  notes written before the design changed are marked "written for an
#            earlier version of design — check them against the current one";
#            what did not change (the requirements) is not named
# V3 [code]  the stage's own output from before the change is marked the same way
# V4 [code]  notes the stage writes after the change are shown as now again
# V5 [code]  notes with no record of what they were written for (from before
#            this rule) are marked, when the stage takes anything it is asked
# V6 [code]  generic: design's notes are marked when the requirements change,
#            and not when design's own output changes
# V7 [guard] a stage whose takes: include no `ask` output gets its notes as now
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

print_test_header "old notes are marked as written for an earlier version (#2575)"
setup_test_env "notes-earlier-version"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

PROOT="$TEST_TEMP_DIR/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$ART"

# _stage <kind> <name> <takes-topics|-> <output-id>:<file>:<topic>[:primary]...
_stage() {
    local kind="$1" s="$2" takes="$3" o id f t p; shift 3
    mkdir -p "$PROOT/$kind/$s"
    {
        printf 'id: %s\nname: %s\nkind: %s\nversion: 0.0.1\n' "$s" "$s" "$kind"
        if [[ "$takes" != - ]]; then
            printf 'takes:\n'
            for t in $takes; do printf '  - topic: %s\n    for: x\n' "$t"; done
        fi
        printf 'hooks:\n  run: x_run\noutputs:\n'
        for o in "$@"; do
            IFS=: read -r id f t p <<< "$o"
            printf '  - id: %s\n    path: ${artifact_dir}/%s\n    required: false\n    topic: %s\n' "$id" "$f" "$t"
            [[ "$p" == primary ]] && printf '    primary: true\n'
        done
    } > "$PROOT/$kind/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/$kind/$s/plugin.sh"
}

init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
_stage agent nv-intake "-" "requirements:requirements.json:ask" "nv_intake_result:nv-intake-result.json:ask:primary"
_stage agent nv-design "ask design-findings" "design:design.md:ask" "nv_design_result:nv-design-result.json:design-findings:primary"
_stage agent nv-build "ask change code-findings" "nv_build_result:nv-build-result.json:change:primary"
_stage agent nv-lens "change" "nv_lens_result:nv-lens-result.json:code-findings:primary"
_TPL_STAGES=(nv-intake nv-design nv-build nv-lens)
for s in nv-intake nv-design nv-build nv-lens; do
    stage_result_write "$ART/$s-result.json" pass "ok" >/dev/null
    _update_stage_status "$STATE/pipeline-state.json" "$s" complete
    _zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" "$s" pass
done
printf '{"requirements":[{"id":"R1","text":"the claim reads plugin.sh"}]}\n' > "$ART/requirements.json"
printf '# Design v1\nclaim.sh sources plugin.sh\n' > "$ART/design.md"

# What a stage's dispatch composes: its Previous work, as the engine writes it.
_pw() { zb_test_previous_work "$STATE/pipeline-state.json" "$PROOT" "$1"; }
_notes() { local n; n="$(stage_notes_path "$STATE" "$1")"; mkdir -p "${n%/*}"; printf '%s\n' "$2" > "$n"; }
UNMARKED="Your notes so far (where they disagree with a list or a result elsewhere in this prompt, the list or the result is right):"

print_test_section "V1: notes written for the design as it is"
_pw nv-build >/dev/null                       # build's first call: no notes yet
_notes nv-build "Status: COMPLETE — claim.sh sources plugin.sh"   # what that call wrote
_o1="$(_pw nv-build)"
assert_contains "[V1] the notes come back" "$_o1" "Status: COMPLETE — claim.sh sources plugin.sh"
assert_contains "[V1] ...as now, under the plain line" "$_o1" "$UNMARKED"
assert_eq "[V1] ...with no earlier-version mark" "0" "$(grep -c 'earlier version' <<< "$_o1" || true)"

print_test_section "V2/V3: the design changed after the notes were written"
printf '# Design v2\nplugin.sh sources claim.sh (reversed)\n' > "$ART/design.md"
_o2="$(_pw nv-build)"
assert_contains "[V2] the notes are marked as written for an earlier version of the design" "$_o2" \
    "Your notes so far, written for an earlier version of design — check them against the current one"
assert_eq "[V2] ...and the requirements, unchanged, are not named" "0" \
    "$(grep 'earlier version' <<< "$_o2" | grep -c 'requirements' || true)"
assert_contains "[V2] ...the notes are still there to check" "$_o2" "Status: COMPLETE — claim.sh sources plugin.sh"
assert_contains "[V3] the stage's own output is marked the same way" "$_o2" \
    "Your output below was written for an earlier version of design — check it against the current one."

print_test_section "V4: notes written after the change"
_notes nv-build "Rebuilt for design v2"
_o4="$(_pw nv-build)"
assert_contains "[V4] notes written after the change are shown as now" "$_o4" "$UNMARKED"
assert_eq "[V4] ...unmarked, notes and output" "0" "$(grep -c 'earlier version' <<< "$_o4" || true)"
_o4b="$(_pw nv-build)"
assert_eq "[V4] ...and stay so while nothing changes" "0" "$(grep -c 'earlier version' <<< "$_o4b" || true)"

print_test_section "V5: notes with no record of what they were written for"
_nb="$(stage_notes_path "$STATE" nv-build)"
rm -f "${_nb%.md}".* 2>/dev/null; _notes nv-build "notes from before this rule"
_o5="$(_pw nv-build)"
assert_contains "[V5] they are marked as written for an earlier version" "$_o5" \
    "Your notes so far, written for an earlier version of design and requirements — check them against the current one"

print_test_section "V6: every stage — design and its requirements"
_pw nv-design >/dev/null
_notes nv-design "design notes"
_o6a="$(_pw nv-design)"
assert_eq "[V6] design's notes, with the requirements as they were, are as now" "0" "$(grep -c 'earlier version' <<< "$_o6a" || true)"
printf '# Design v3\n' > "$ART/design.md"
_o6b="$(_pw nv-design)"
assert_eq "[V6] ...design's own output changing does not mark them" "0" "$(grep -c 'earlier version' <<< "$_o6b" || true)"
printf '{"requirements":[{"id":"R1","text":"plugin.sh reads claim.sh"}]}\n' > "$ART/requirements.json"
_o6c="$(_pw nv-design)"
assert_contains "[V6] ...the requirements changing does" "$_o6c" \
    "Your notes so far, written for an earlier version of requirements — check them against the current one"

print_test_section "V7: a stage that takes nothing asked"
_pw nv-lens >/dev/null
_notes nv-lens "lens notes"
printf '# Design v4\n' > "$ART/design.md"
_o7="$(_pw nv-lens)"
assert_contains "[V7] its notes come back as now" "$_o7" "$UNMARKED"
assert_eq "[V7] ...unmarked" "0" "$(grep -c 'earlier version' <<< "$_o7" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
