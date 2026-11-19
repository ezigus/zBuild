#!/usr/bin/env bash
# tests/unit/design-check-every-part-test.sh — design's check judges every part
# of the design against everything intake gave (#2567, ADR-073 §5).
#
# Why: on #1764 run 44417314654 the check was shown the issue's TERMS ("The
# engine calls its claim and release hooks through the plugin registry. The
# label calls live in the plugin, not in core/") and the steps "Create
# core/claim/claim.sh … wire into runner.sh", and answered "Steps: ok" on every
# try: its prompt held the terms against SPEC lines only, and asked the steps
# one thing, whether they built a new owner. A step carried from older designs
# ("… trigger the shape floor") had no requirement behind it and set off a loop.
#
# E1 [change] the prompt states one rule for every part — SPEC lines, steps,
#             decisions — against requirements, limits, terms and the issue's
#             words, new or carried over; and the Steps and Decision forms
# E2 [change] `Steps: contradicts | WHY | QUOTE: <the step's words>` is a
#             finding for design naming the step
# E3 [change] `Steps: not-asked | …` is a finding for design naming the step
# E4 [change] a step quote that is not the steps' words cannot be used
# E5 [change] the decisions are judged: `Decision: contradicts | …` is a finding
# E6 [change] a design with decisions needs a Decision line; an answer without
#             one is asked again, naming it
# E7 [guard]  an old `Steps: new-owner | … | QUOTE: <file> | <line>` still reads
# E8 [guard]  a design with no decisions is asked no Decision line
# E9 [change] a decisions-only change asks only the Decision line again; the
#             kept answers stand; (review) the requirements and the issue's
#             words are shown to it, though not asked
# E10 [change] (review) the decisions are the design's prose outside its blocks,
#             whatever its heading: an `## Architectural Decision Summary` with
#             `**Decision.**` is judged; prose after a block inside the section
#             is kept; UNCLEAR/REMOVED/WIRING lines and their wrapped lines are not
# E11 [change] (review) a Steps/Decision quote must lie in one step line, or one
#             line of the decisions, and be at least three words
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's check judges every part of the design (#2567)"
setup_test_env "design-check-every-part"

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

## Decision
The claim lives in core/claim/claim.sh, which calls gh issue edit itself.

```steps
- Create core/claim/claim.sh: thin wiring bridge that adds zbuild:claimed | areas: core/claim/claim.sh
- Add core/claim/claim.sh to config/shape-change-paths.txt so future changes trigger the shape floor | areas: config/shape-change-paths.txt
```
```acceptance
CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1
  When: a run starts on an issue with no claimed label
  Then: the claimed label is on the issue
WIRING: core/pipeline/runner.sh
```
MD
REQS='- RQCL-1: the run adds the claimed label before the first stage'
TERMS='- **Claim coordinator:** the ADR-005 plugin kind. The engine calls its claim and release hooks through the plugin registry. The label calls (gh issue edit) live in the plugin, not in core/.'
QCODE='plugins/claim/plugin.sh | claim_coordinator_claim() { gh issue edit "$1" --add-label "$2"; }'
OK=$'RQCL-1: covered\nCLA-1: ok'
_run() { : > "$_P_FILE"; _REPLY="$1"; ZBUILD_REPO_ROOT="$XR" _design_coverage "${2:-$D}" "$REQS" T2 "" "" "$TERMS"; FX="$(_design_coverage_findings)"; }

print_test_section "E1: one rule for every part"
_run "$OK"$'\nSteps: ok\nDecision: ok'
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
assert_contains "[E1] one rule: every part judged against everything intake gave" "$_P" \
    "Judge every part of the design — each SPEC line, the steps and the decisions — against everything the issue gives you: its REQUIREMENTS, its LIMITS, its TERMS and its own words."
assert_contains "[E1] ...new or carried over" "$_P" "A part carried over from an earlier design is judged the same as a new one."
assert_contains "[E1] ...a step no requirement needs" "$_P" "Steps: not-asked | WHY: <no requirement needs this step> | QUOTE: <the step's words>"
assert_contains "[E1] ...a step against the issue" "$_P" "Steps: contradicts | WHY: <which requirement, limit or term, and how> | QUOTE: <the step's words>"
assert_contains "[E1] ...the decisions" "$_P" "Decision: contradicts | WHY: <which requirement, limit or term, and how> | QUOTE: <the decisions' words>"
assert_contains "[E1] ...shown the decisions" "$_P" "The claim lives in core/claim/claim.sh, which calls gh issue edit itself."
assert_contains "[E1] ...terms held against any part" "$_P" "Any part of the design — a SPEC line, a step, the decisions — that uses a term differently from its definition contradicts it"

print_test_section "E2-E4: the steps"
_run "$OK"$'\nSteps: contradicts | WHY: the label calls belong in the plugin, not core/ | QUOTE: Create core/claim/claim.sh: thin wiring bridge that adds zbuild:claimed\nDecision: ok'
assert_eq "[E2] a contradicting step is read" "" "$_DESIGN_COV_OUTCOME"
assert_contains "[E2] ...a finding for design naming the step" "$FX" \
    "Steps: a step goes against the issue: the label calls belong in the plugin, not core/ — Create core/claim/claim.sh: thin wiring bridge that adds zbuild:claimed [FIX IN DESIGN:"
_run "$OK"$'\nSteps: not-asked | WHY: no requirement asks for shape tests | QUOTE: Add core/claim/claim.sh to config/shape-change-paths.txt\nDecision: ok'
assert_contains "[E3] a step no requirement needs is a finding naming it" "$FX" \
    "Steps: a step no requirement needs: no requirement asks for shape tests — Add core/claim/claim.sh to config/shape-change-paths.txt [FIX IN DESIGN:"
_run "$OK"$'\nSteps: not-asked | WHY: w | QUOTE: no such step words\nDecision: ok'
assert_eq "[E4] a step quote not in the steps cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"
assert_contains "[E4] ...and the re-ask names the quote" "$(cat "$_P_FILE")" "Steps's quote"

print_test_section "E11: a quote names one part"
_run "$OK"$'\nSteps: not-asked | WHY: w | QUOTE: the\nDecision: ok'
assert_eq "[E11] a one-word quote cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"
_run "$OK"$'\nSteps: not-asked | WHY: w | QUOTE: adds zbuild:claimed | areas: core/claim/claim.sh - Add core/claim/claim.sh\nDecision: ok'
assert_eq "[E11] a quote spanning two steps cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"
_run "$OK"$'\nSteps: not-asked | WHY: no requirement asks for it | QUOTE: to config/shape-change-paths.txt so future changes\nDecision: ok'
assert_eq "[E11] a quote within one step is used" "" "$_DESIGN_COV_OUTCOME"

print_test_section "E5/E6: the decisions"
_run "$OK"$'\nSteps: ok\nDecision: contradicts | WHY: the terms put the label calls in the plugin | QUOTE: which calls gh issue edit itself'
assert_eq "[E5] a contradicting decision is read" "" "$_DESIGN_COV_OUTCOME"
assert_contains "[E5] ...a finding for design" "$FX" \
    "Decision: the design's decisions go against the issue: the terms put the label calls in the plugin — which calls gh issue edit itself [FIX IN DESIGN:"
_run "$OK"$'\nSteps: ok'
assert_eq "[E6] no Decision line: the answer cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"
assert_contains "[E6] ...and the re-ask names it" "$(cat "$_P_FILE")" "Answer again only for: the Decision line"

print_test_section "E7/E8: guards"
_run "$OK"$'\nSteps: new-owner | WHY: the plugin already adds the label | QUOTE: '"$QCODE"$'\nDecision: ok'
assert_contains "[E7] an old new-owner line still reads" "$FX" "Steps: the design's steps build a new owner where one exists: the plugin already adds the label"
D2="$TEST_TEMP_DIR/nodecision.md"
/usr/bin/grep -v -e '^## Decision' -e '^The claim lives' "$D" > "$D2"
_run "$OK"$'\nSteps: ok' "$D2"
assert_eq "[E8] no decisions: no Decision line is needed" "" "$_DESIGN_COV_OUTCOME"
assert_eq "[E8] ...nor asked" "0" "$(grep -c 'Decision: ok' "$_P_FILE" || true)"

print_test_section "E9: kept answers"
export artifact_dir="$TEST_TEMP_DIR/kept"; mkdir -p "$artifact_dir"
jq -nc '{result_contract: 3, outcome: "pass", reason: "r", data: {issue_text: "ISSUE-WORDS-2567: claim through the coordinator"}}' > "$artifact_dir/intake-result.json"
_run "$OK"$'\nSteps: ok\nDecision: ok'
sed -i.bak 's/which calls gh issue edit itself/which calls the plugin hooks/' "$D"
_run $'Decision: ok'
assert_eq "[E9] a decisions-only change: the kept answers stand" "" "$_DESIGN_COV_OUTCOME"
assert_eq "[E9] ...the requirements are not asked again" "0" "$(grep -c 'One line for every requirement' "$_P_FILE" || true)"
assert_contains "[E9] ...the decisions are" "$(cat "$_P_FILE")" "which calls the plugin hooks"
assert_contains "[E9] ...shown the requirements, though not asked" "$(cat "$_P_FILE")" "RQCL-1: the run adds the claimed label before the first stage"
assert_contains "[E9] ...and the issue's own words" "$(cat "$_P_FILE")" "ISSUE-WORDS-2567: claim through the coordinator"
unset artifact_dir; mv "$D.bak" "$D"

print_test_section "E10: the decisions, as designs write them"
D3="$TEST_TEMP_DIR/summary.md"
cat > "$D3" <<'MD'
# Design — GitHub label claim

## Architectural Decision Summary

**Goal.** One shared label for every machine.

**Decision.** The claim lives in core/claim/claim.sh, which calls gh issue edit itself.

```text
an example, not a decision
```

After the example the decision goes on: release runs in the EXIT trap.

UNCLEAR: RQCL-1 | which comment? |
the run-status comment

REMOVED: CLA-9 — covered by CLA-1

```steps
- Create core/claim/claim.sh: thin wiring bridge | areas: core/claim/claim.sh
```
```acceptance
CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1
  When: a run starts on an issue with no claimed label
  Then: the claimed label is on the issue
WIRING: core/pipeline/runner.sh
```
MD
_dv=""; _dcov_decision_v _dv "$D3"
assert_contains "[E10] a **Decision.** under any heading is a decision" "$_dv" "The claim lives in core/claim/claim.sh, which calls gh issue edit itself."
assert_contains "[E10] ...and the rest of the design's prose" "$_dv" "One shared label for every machine."
assert_contains "[E10] ...prose after a block inside the section is kept" "$_dv" "release runs in the EXIT trap"
assert_eq "[E10] ...a block's text is not" "0" "$(grep -c 'an example, not a decision' <<< "$_dv" || true)"
assert_eq "[E10] ...nor an UNCLEAR line or its wrapped line" "0" "$(grep -c -e 'UNCLEAR' -e 'the run-status comment' <<< "$_dv" || true)"
assert_eq "[E10] ...nor a REMOVED line" "0" "$(grep -c 'REMOVED' <<< "$_dv" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
