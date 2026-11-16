#!/usr/bin/env bash
# tests/unit/design-one-form-test.sh — design's check answers every problem in
# one form, naming the line it is about; it flags a design that builds a new
# owner where one exists; and design is told to build on what exists (#2555,
# ADR-073, ADR-072).
#
# Why: on #1764 run 43772987273 the check wrote `DSCLA-10 Then: outside`,
# naming a line on a verdict whose form took none. The answer was refused
# twice and thrown away, and design was told only "the check could not be run".
# In the same run design put the claim in a new core/claim/claim.sh on every
# try: it never looked at plugins/claim-coordinator/, which already had the
# hooks, and nothing asked it to.
#
# F1 [change] the check's prompt gives one form: <SPEC id> <line>: <problem>,
#             <line> one of Title, Given, When, Then, And, Cleanup; not-asked
#             replaces outside
# F2 [change] `<id> Then: not-asked | WHY | QUOTE` is read: a finding on that
#             Then line, with its WHY
# F3 [change] `<id> Title: not-asked` is a finding on the SPEC's first line
# F4 [change] `<id> Title: status | DOC | BEFORE | WORK | WHY | QUOTE` is read
#             as before
# F5 [change] the old `<id>: outside` and `<id>: status` lines are refused, and
#             the re-ask says to name the line
# F6 [change] status on any line but Title is refused
# F7 [change] the check is asked whether the design's steps build a new owner
#             where one exists; `Steps: new-owner | WHY | QUOTE: <file> |
#             <line>` is a finding for design; a quote not in the code is
#             refused; no Steps line is no finding
# F7b [change] (review) the steps are an item of their own: a design with a
#             steps block needs a Steps line, and an answer without one is
#             asked again, naming it; a steps-only change asks only Steps again
# F7c [change] (review) the new-owner quote is checked in the code from before
#             the change only: a file only the working copy has is refused
# F7d [change] (review) design's `wrong` answer to a new-owner finding is a
#             dispute of the steps only
# F9  [change] a reply's `<id> Title:` and `Steps:` lines each start a unit
# F10 [change] (review) a SPEC that builds a new owner: `<id> Title: new-owner |
#             WHY | QUOTE: <file> | <line>`, a finding on its first line
# F11 [change] (review, R6) when one item's lines still cannot be used, the
#             findings the usable items gave reach design, with their WHY, and
#             a note names what was not judged
# F8 [change] design's prompt asks it to find what already owns the job, build
#             on it, and name what it found
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's check answers in one form; design builds on what exists (#2555)"
setup_test_env "design-one-form"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

_P_FILE="$TEST_TEMP_DIR/prompt.txt"
route_to_model() { printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

XR="$TEST_TEMP_DIR/repo"; BASE="$TEST_TEMP_DIR/base"
mkdir -p "$XR/plugins/claim" "$BASE/plugins/claim"
printf 'claim_coordinator_claim() { gh issue edit "$1" --add-label "$2"; }\n' > "$BASE/plugins/claim/plugin.sh"
cp "$BASE/plugins/claim/plugin.sh" "$XR/plugins/claim/plugin.sh"
export _DESIGN_BASE_DIR="$BASE"

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Design
```steps
- Create core/claim/claim.sh with zbuild_claim_acquire | areas: core/claim/claim.sh
```
```acceptance
CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1
  When: a run starts on an issue with no claimed label
  Then: the claimed label is on the issue
  And: pipeline.refused.claimed is emitted to the event bus
WIRING: core/pipeline/runner.sh
```
MD
REQS='- RQCL-1: the run adds the claimed label before the first stage'
QCODE='plugins/claim/plugin.sh | claim_coordinator_claim() { gh issue edit "$1" --add-label "$2"; }'
_run() { : > "$_P_FILE"; _REPLY="$1"; ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2; FX="$(_design_coverage_findings)"; }

print_test_section "F1: the one form"
_run $'RQCL-1: covered\nCLA-1: ok'
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
assert_contains "[F1] one form for every problem" "$_P" "<SPEC id> <line>: <problem> | WHY: <why> | QUOTE: <words from that line>"
assert_contains "[F1] ...the line is one of six" "$_P" "<line> is the word the line starts with: Title (the SPEC's first line), Given, When, Then, And or Cleanup."
assert_contains "[F1] ...not-asked names the line that asks for what the issue does not" "$_P" \
    "not-asked — the line commits to something the issue does not ask for, or contradicts it"
assert_contains "[F1] ...status is on Title" "$_P" "<SPEC id> Title: status | DOC: <yes or no> | BEFORE: <yes or no> | WORK: <yes or no> | WHY: <what shows it> | QUOTE: <file> | <one line of it>"
assert_contains "[F10] a SPEC can be flagged as a new owner" "$_P" "new-owner — only on Title: the SPEC builds something new for a job"
assert_eq "[F1] ...and the old outside form is gone" "0" "$(grep -c '<SPEC id>: outside' <<< "$_P" || true)"

print_test_section "F2/F3/F4: a problem on the line it is about"
_run $'RQCL-1: covered\nCLA-1 And: not-asked | WHY: no requirement asks for an event | QUOTE: pipeline.refused.claimed is emitted to the event bus'
assert_eq "[F2] a not-asked And is read: the answer is used" "" "$_DESIGN_COV_OUTCOME"
assert_contains "[F2] ...a finding on that line, with its WHY" "$FX" \
    "And: pipeline.refused.claimed is emitted to the event bus [FIX IN DESIGN: no requirement asks for an event — the issue does not ask for this; take it out, or make it what the issue asks]"
_run $'RQCL-1: covered\nCLA-1 Title: not-asked | WHY: the issue asks for no stage order | QUOTE: before the first stage'
assert_contains "[F3] a not-asked Title is a finding on the first line" "$FX" \
    "CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1 [FIX IN DESIGN: the issue asks for no stage order — the issue does not ask for this"
_run "RQCL-1: covered
CLA-1 Title: status | DOC: no | BEFORE: yes | WORK: no | WHY: the plugin already adds the label | QUOTE: $QCODE"
assert_contains "[F4] a status on Title is read as before" "$FX" "it is [done], not [code]"

print_test_section "F5/F6: the old form and status off Title are refused"
_run $'RQCL-1: covered\nCLA-1: outside | WHY: no event asked | QUOTE: pipeline.refused.claimed is emitted to the event bus'
assert_eq "[F5] the old outside line is refused" "unusable" "$_DESIGN_COV_OUTCOME"
assert_contains "[F5] ...and the re-ask says to name the line" "$(cat "$_P_FILE")" \
    "CLA-1: a problem is written on the line it is about: CLA-1 Title: … or CLA-1 Then: …"
_run "RQCL-1: covered
CLA-1: status | DOC: no | BEFORE: yes | WORK: no | WHY: already | QUOTE: $QCODE"
assert_eq "[F5] the old status line is refused" "unusable" "$_DESIGN_COV_OUTCOME"
_run "RQCL-1: covered
CLA-1 When: status | DOC: no | BEFORE: yes | WORK: no | WHY: already | QUOTE: $QCODE"
assert_eq "[F6] status on a When is refused" "unusable" "$_DESIGN_COV_OUTCOME"

print_test_section "F7: a new owner where one exists"
_run $'RQCL-1: covered\nCLA-1: ok'
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
assert_contains "[F7] the check is asked about the design's steps" "$_P" \
    "Steps: new-owner | WHY: <what the steps build, and what already owns that job> | QUOTE: <file> | <one line of the existing owner>"
_run "RQCL-1: covered
CLA-1: ok
Steps: new-owner | WHY: the steps build core/claim/claim.sh, but the claim coordinator plugin already adds the label | QUOTE: $QCODE"
assert_eq "[F7] a new-owner line is read" "" "$_DESIGN_COV_OUTCOME"
assert_contains "[F7] ...a finding for design, with its WHY and the existing owner" "$FX" \
    "Steps: the design's steps build a new owner where one exists: the steps build core/claim/claim.sh, but the claim coordinator plugin already adds the label — $QCODE [FIX IN DESIGN: build on what exists, or say in the design why it cannot]"
_run $'RQCL-1: covered\nCLA-1: ok\nSteps: new-owner | WHY: there is one | QUOTE: plugins/claim/plugin.sh | no such line'
assert_eq "[F7] a new-owner quote not in the code is refused" "unusable" "$_DESIGN_COV_OUTCOME"
_run $'RQCL-1: covered\nCLA-1: ok\nSteps: ok'
assert_eq "[F7] Steps: ok is no finding" "" "$FX"

_run $'RQCL-1: covered\nCLA-1: ok'
assert_eq "[F7b] a design with steps and no Steps line: the answer cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"
assert_contains "[F7b] ...and the re-ask names the Steps line" "$(cat "$_P_FILE")" "Answer again only for: the Steps line"
mkdir -p "$XR/core"; printf 'zbuild_claim_acquire() { :; }\n' > "$XR/core/new.sh"
_run $'RQCL-1: covered\nCLA-1: ok\nSteps: new-owner | WHY: it exists | QUOTE: core/new.sh | zbuild_claim_acquire() { :; }'
assert_eq "[F7c] a new-owner quote only the working copy has is refused" "unusable" "$_DESIGN_COV_OUTCOME"
# Kept answers: a steps-only change asks only the Steps line again.
export artifact_dir="$TEST_TEMP_DIR/kept"; mkdir -p "$artifact_dir"
_run $'RQCL-1: covered\nCLA-1: ok\nSteps: ok'
sed -i.bak 's/Create core\/claim\/claim.sh/Call the claim coordinator/' "$D"
_run $'Steps: ok'
assert_eq "[F7b] a steps-only change: the kept answers stand and only Steps is asked" "" "$_DESIGN_COV_OUTCOME"
assert_eq "[F7b] ...the requirements are not asked again" "0" "$(grep -c 'One line for every requirement' "$_P_FILE" || true)"
assert_contains "[F7b] ...the steps are" "$(cat "$_P_FILE")" "Steps: new-owner | WHY:"
unset artifact_dir; mv "$D.bak" "$D"
# F7d: a `wrong` answer to the steps' finding disputes the steps only.
_d7d() {
    local -a ids=(CLA-1); local -A first=([CLA-1]=x) req_text=([RQCL-1]=y) dd=()
    jq -n '{data: {findings: [{n: 1, text: "Steps: the design'"'"'s steps build a new owner where one exists: x"}]}}' > "$TEST_TEMP_DIR/v.json"
    _dcov_disputes_v dd "design finding 1: wrong — the coordinator cannot do it" "$TEST_TEMP_DIR/v.json"
    printf '%s\n' "${!dd[@]}" | sort | tr '\n' ' '
}
assert_eq "[F7d] a wrong answer to the steps' finding disputes only the steps" "steps " "$(_d7d)"

print_test_section "F9/F10/F11"
_j=""; zb_reply_join_v _j $'RQCL-1: covered\nCLA-1 Title: not-asked | WHY: w | QUOTE: q\nSteps: ok'
assert_eq "[F9] Title and Steps lines each start a unit" "3" "$(grep -c . <<< "$_j")"
_run "RQCL-1: covered
CLA-1 Title: new-owner | WHY: the plugin already adds the label | QUOTE: $QCODE
Steps: ok"
assert_contains "[F10] a SPEC that builds a new owner: a finding on its first line" "$FX" \
    "covers: RQCL-1 [FIX IN DESIGN: the plugin already adds the label — it builds a new owner where one exists: $QCODE; build on it, or say why it cannot]"
D2="$TEST_TEMP_DIR/two.md"
printf '%s\n' '# Design' '```acceptance' 'CLA-1[code]: the run adds the label covers: RQCL-1' \
    'CLA-2[code]: the run releases the label covers: RQCL-1' 'WIRING: x' '```' > "$D2"
: > "$_P_FILE"; _REPLY=$'RQCL-1: covered\nCLA-1 Title: not-asked | WHY: no requirement asks for it | QUOTE: adds the label\nCLA-2 Title: not-asked | WHY: w | QUOTE: no such words'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$D2" "$REQS" T2; FX="$(_design_coverage_findings)"
assert_contains "[F11] the usable item's finding reaches design, with its WHY" "$FX" "no requirement asks for it — the issue does not ask for this"
assert_contains "[F11] ...and a note names what was not judged" "$FX" "the check could not judge CLA-2:"

print_test_section "F8: design builds on what exists"
FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX/state/artifacts"
git -C "$FIX" init -q >/dev/null 2>&1
jq -n '{schema_version: 1, requirements: [{id: "RQCL-1", text: "the run adds the claimed label"}]}' > "$FIX/state/requirements.json"
jq -n --arg r "$FIX/state/requirements.json" '{inputs: {a: $r}}' > "$FIX/state/stage-inputs.json"
printf 'scope: all\n' > "$FIX/state/scope-manifest.md"
( route_to_model() { return 1; }
  _route_loop_close_final_banner() { return 0; }
  export ZBUILD_REPO_ROOT="$FIX" ZBUILD_STAGE_INPUTS="$FIX/state/stage-inputs.json"
  _design_stage_run_inner "$FIX/state/scope-manifest.md" "$FIX/state/artifacts/design.md" "$FIX/state/artifacts" ) >/dev/null 2>&1
_dp="$(tr -s '[:space:]' ' ' < "$FIX/state/artifacts/design-prompt.txt" 2>/dev/null)"
assert_contains "[F8] design is told to find what already owns the job" "$_dp" \
    "Before you add a file or a mechanism, find what already owns the job"
assert_contains "[F8] ...where to look" "$_dp" "the plugin kinds in docs/ARCHITECTURE.md, the ADRs for the area, the existing plugins and libraries"
assert_contains "[F8] ...build on it, and name what it found" "$_dp" \
    "Build on it, not beside it. Name in the design what you found and why you used it or not."

cleanup_test_env
print_test_results
exit $((FAIL > 0))
