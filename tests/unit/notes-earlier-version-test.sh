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
# Review on #2575:
# V8 [code]  the output mark stays on every prompt built until the stage writes
#            a new result: two builds in a row after a design change both show
#            it (a retry that wrote nothing keeps it); a new result clears it
# V9 [code]  only what defines the ask counts: the design's prose changing, its
#            draft changing, or the issue text changing marks nothing; its steps
#            (design-steps.json, from design's writer) or its SPECs changing does
# V10 [code] the record beside the notes holds fingerprints, not copies: neither
#            the notes nor the design are in it, and no temp file is left
# V11 [code] a byte after a NUL in an input still counts
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
# shellcheck source=../../scripts/lib/design-steps.sh
source "$REPO_ROOT/scripts/lib/design-steps.sh"

print_test_header "old notes are marked as written for an earlier version (#2575)"
setup_test_env "notes-earlier-version"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

PROOT="$TEST_TEMP_DIR/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$ART"

# _stage <kind> <name> <takes-topics|-> <id>:<file>:<topic>[:primary|:required]...
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
            printf '  - id: %s\n    path: ${artifact_dir}/%s\n    topic: %s\n' "$id" "$f" "$t"
            case "$p" in
                primary) printf '    required: true\n    primary: true\n' ;;
                required) printf '    required: true\n' ;;
                *) printf '    required: false\n' ;;
            esac
        done
    } > "$PROOT/$kind/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/$kind/$s/plugin.sh"
}

init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
_stage agent nv-intake "-" "requirements:requirements.json:ask" "intake_goal:intake.md:ask:required" \
    "nv_intake_result:nv-intake-result.json:ask:primary"
_stage agent nv-design "ask design-findings" "design:design.md:ask:required" "work_steps:design-steps.json:ask" \
    "design_draft:design-draft.md:ask" "nv_design_result:nv-design-result.json:design-findings:primary"
_stage agent nv-build "ask change code-findings" "nv_build_result:nv-build-result.json:change:primary"
_stage agent nv-lens "change" "nv_lens_result:nv-lens-result.json:code-findings:primary"
_TPL_STAGES=(nv-intake nv-design nv-build nv-lens)
# nv-build's result is written by its first call, below.
for s in nv-intake nv-design nv-build nv-lens; do
    [[ "$s" == nv-build ]] || stage_result_write "$ART/$s-result.json" pass "ok" >/dev/null
    _update_stage_status "$STATE/pipeline-state.json" "$s" complete
    _zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" "$s" pass
done
printf '{"requirements":[{"id":"R1","text":"the claim reads plugin.sh"}]}\n' > "$ART/requirements.json"
printf 'The issue, as written.\n' > "$ART/intake.md"
# _design <prose> <step> <spec> — design.md, its draft, and design-steps.json
# written by design's own step writer.
_design() {
    printf '# Design\n%s\n```steps\n- %s | areas: claim.sh\n```\n```acceptance\nSPEC-1[code]: %s\n```\n' \
        "$1" "$2" "$3" > "$ART/design.md"
    cp "$ART/design.md" "$ART/design-draft.md"
    zb_design_write_steps "$ART/design.md" "$ART/design-steps.json"
}
_design "claim.sh sources plugin.sh" "source plugin.sh from claim.sh" "claim.sh reads plugin.sh"

# What a stage's dispatch composes: its Previous work, as the engine writes it.
_pw() { zb_test_previous_work "$STATE/pipeline-state.json" "$PROOT" "$1"; }
_notes() { local n; n="$(stage_notes_path "$STATE" "$1")"; mkdir -p "${n%/*}"; printf '%s\n' "$2" > "$n"; }
UNMARKED="Your notes so far (where they disagree with a list or a result elsewhere in this prompt, the list or the result is right):"

print_test_section "V1: notes written for the design as it is"
_pw nv-build >/dev/null                       # build's first call: no notes yet
_notes nv-build "Status: COMPLETE — claim.sh sources plugin.sh"   # what that call wrote
stage_result_write "$ART/nv-build-result.json" pass "built" >/dev/null
_o1="$(_pw nv-build)"
assert_contains "[V1] the notes come back" "$_o1" "Status: COMPLETE — claim.sh sources plugin.sh"
assert_contains "[V1] ...as now, under the plain line" "$_o1" "$UNMARKED"
assert_eq "[V1] ...with no earlier-version mark" "0" "$(grep -c 'earlier version' <<< "$_o1" || true)"

print_test_section "V2/V3: the design changed after the notes were written"
_design "plugin.sh sources claim.sh (reversed)" "source claim.sh from plugin.sh" "plugin.sh reads claim.sh"
_o2="$(_pw nv-build)"
assert_contains "[V2] the notes are marked as written for an earlier version of the design" "$_o2" \
    "Your notes so far, written for an earlier version of design and work_steps — check them against the current one"
assert_eq "[V2] ...and the requirements, unchanged, are not named" "0" \
    "$(grep 'earlier version' <<< "$_o2" | grep -c 'requirements' || true)"
assert_contains "[V2] ...the notes are still there to check" "$_o2" "Status: COMPLETE — claim.sh sources plugin.sh"
assert_contains "[V3] the stage's own output is marked the same way" "$_o2" \
    "Your output below was written for an earlier version of design and work_steps — check it against the current one."

print_test_section "V4: notes written after the change"
_notes nv-build "Rebuilt for design v2"
stage_result_write "$ART/nv-build-result.json" pass "rebuilt for v2" >/dev/null
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
    "Your notes so far, written for an earlier version of design, requirements and work_steps — check them against the current one"

print_test_section "V6: every stage — design and its requirements"
_pw nv-design >/dev/null
_notes nv-design "design notes"
_o6a="$(_pw nv-design)"
assert_eq "[V6] design's notes, with the requirements as they were, are as now" "0" "$(grep -c 'earlier version' <<< "$_o6a" || true)"
_design "v3" "source claim.sh from plugin.sh, v3" "plugin.sh reads claim.sh, v3"
_o6b="$(_pw nv-design)"
assert_eq "[V6] ...design's own output changing does not mark them" "0" "$(grep -c 'earlier version' <<< "$_o6b" || true)"
printf '{"requirements":[{"id":"R1","text":"plugin.sh reads claim.sh"}]}\n' > "$ART/requirements.json"
_o6c="$(_pw nv-design)"
assert_contains "[V6] ...the requirements changing does" "$_o6c" \
    "Your notes so far, written for an earlier version of requirements — check them against the current one"

print_test_section "V7: a stage that takes nothing asked"
_pw nv-lens >/dev/null
_notes nv-lens "lens notes"
_design "v4" "v4" "v4"
_o7="$(_pw nv-lens)"
assert_contains "[V7] its notes come back as now" "$_o7" "$UNMARKED"
assert_eq "[V7] ...unmarked" "0" "$(grep -c 'earlier version' <<< "$_o7" || true)"

print_test_section "V8: the output mark stays until a new result"
_pw nv-build >/dev/null; _notes nv-build "notes for v4"
stage_result_write "$ART/nv-build-result.json" pass "built for v4" >/dev/null; _pw nv-build >/dev/null
_design "v5" "step v5" "spec v5"
_o8a="$(_pw nv-build)"; _o8b="$(_pw nv-build)"
_om="Your output below was written for an earlier version of"
assert_contains "[V8] the first prompt after the change marks the output" "$_o8a" "$_om"
assert_contains "[V8] ...and so does the next, with no new result written" "$_o8b" "$_om"
stage_result_write "$ART/nv-build-result.json" pass "rebuilt for v5" >/dev/null
_pw nv-build >/dev/null
_o8c="$(_pw nv-build)"
assert_eq "[V8] a result written for the current design clears it" "0" "$(grep -c "$_om" <<< "$_o8c" || true)"

print_test_section "V9: only what defines the ask counts"
_notes nv-build "notes for v5"; _pw nv-build >/dev/null
_design "the prose is rewritten, every word of it" "step v5" "spec v5"
printf 'scratch draft\n' > "$ART/design-draft.md"
printf 'The issue, edited.\n' > "$ART/intake.md"
_o9a="$(_pw nv-build)"
assert_eq "[V9] prose, draft and issue text changing mark nothing" "0" "$(grep -c 'earlier version' <<< "$_o9a" || true)"
_design "the prose is rewritten, every word of it" "step v6" "spec v5"
_o9b="$(_pw nv-build)"
assert_contains "[V9] a step changing marks the notes, naming the steps" "$_o9b" \
    "Your notes so far, written for an earlier version of work_steps — check them against the current one"
_notes nv-build "notes for v6"; _pw nv-build >/dev/null
_design "the prose is rewritten, every word of it" "step v6" "spec v6"
_o9c="$(_pw nv-build)"
assert_contains "[V9] a SPEC changing marks them, naming the design" "$_o9c" \
    "Your notes so far, written for an earlier version of design — check them against the current one"

print_test_section "V10: fingerprints, not copies"
_rec="$(cat "${_nb%.md}.asked" 2>/dev/null)"
assert_eq "[V10] the record is there" "yes" "$([[ -n "$_rec" ]] && echo yes || echo no)"
assert_eq "[V10] ...without the notes in it" "0" "$(grep -c 'notes for v6' <<< "$_rec" || true)"
assert_eq "[V10] ...or the design" "0" "$(grep -c 'spec v6' <<< "$_rec" || true)"
assert_eq "[V10] no temp file is left beside it" "0" "$(find "${_nb%/*}" -name '*.asked.*' | wc -l | tr -d ' ')"

print_test_section "V11: a NUL in an input"
_nul() { printf '# Design\n```steps\n- step v6 | areas: claim.sh\n```\n```acceptance\nSPEC-1[code]: spec\0%s\n```\n' "$1" > "$ART/design.md"; }
_nul one; _pw nv-build >/dev/null; _notes nv-build "notes after nul one"; _pw nv-build >/dev/null
_nul two
_o11="$(_pw nv-build)"
assert_contains "[V11] a change after the NUL marks the notes" "$_o11" \
    "written for an earlier version of design"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
