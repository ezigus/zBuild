#!/usr/bin/env bash
# tests/unit/design-unclear-review-test.sh — design's side of the questions it
# carries holds (#2571 review, ADR-069 §12, ADR-073 §5, ADR-072 §4).
#
# Why: review of #2571 found that design's check kept an `open` answer after
# the issue's text changed; that a carried question the check left unjudged
# failed the whole try; that a design restored from an earlier run, in the old
# form, cost a try to learn the one form; that design could drop a question
# with no check retiring it; and that design was shown a stray `)`.
#
# DR1 [change] the check's kept answer on the questions is judged again when the
#              issue's text changes, and kept while it does not
# DR2 [change] a carried question the check leaves unjudged after the one re-ask
#              stays open: no unusable outcome, the other items' answers kept, a
#              note says so, and the next try judges it
# DR3 [change] design's prompt names each old-form UNCLEAR line of the design it
#              refines, to be rewritten in the one form, before it writes
# DR4 [change] a question of the last design that passed that the new design
#              dropped, with no check retiring it, is refused; one the check
#              retired may go
# DR5 [change] the form design is told for a malformed UNCLEAR line has no stray `)`
# DR6 [change] two questions on one requirement id in a design are refused,
#              told to give each its own id
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's questions hold (#2571 review)"
setup_test_env "design-unclear-review"
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

_P_FILE="$TEST_TEMP_DIR/prompt.txt"; _C_FILE="$TEST_TEMP_DIR/calls"; _REPLIES=()
# Each call takes the next reply; the last one repeats. The call runs in a
# command substitution, so it is counted in a file.
route_to_model() {
    local n=0; [[ -s "$_C_FILE" ]] && n="$(wc -l < "$_C_FILE")"; n=$(( n + 0 ))
    printf 'x\n' >> "$_C_FILE"; printf '%s' "$2" >> "$_P_FILE"
    printf '%s' "${_REPLIES[$n]:-${_REPLIES[-1]}}"; return 0
}
XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
export artifact_dir="$TEST_TEMP_DIR/art"; mkdir -p "$artifact_dir"
_issue() {
    stage_result_write "$artifact_dir/intake-result.json" pass "took in the issue" \
        "$(jq -nc --arg t "$1" '{goal_len: ($t | length), issue_text: $t}')"
}
ISSUE='## Terms
- **Run-status comment:** the comment ADR-064 already posts and edits for every run. Not a new comment.

## Required behavior
- **R2.** The holder is in the run-status comment.'
_issue "$ISSUE"
D="$TEST_TEMP_DIR/design-draft.md"
cat > "$D" <<'MD'
# Design

UNCLEAR RQADR-2 | "The holder is in the run-status comment" | a new comment, or the ADR-064 one | ASSUMED: the ADR-064 one

```acceptance
DSHOLD-1[code]: the holder is shown in the run-status comment covers: RQADR-2
  When: a run claims the issue
  Then: the run-status comment names the holder
WIRING: none
```
MD
REQS='- RQADR-2: The holder is in the run-status comment.'
OK=$'RQADR-2: covered\nDSHOLD-1: ok'
_run() {
    : > "$_P_FILE"; : > "$_C_FILE"; _REPLIES=("$@")
    ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2 "" "" ""
    FX="$(_design_coverage_findings)"; _CALLS=0; [[ -s "$_C_FILE" ]] && _CALLS="$(wc -l < "$_C_FILE")"; _CALLS=$(( _CALLS + 0 ))
}

print_test_section "DR1: a change to the issue's text is judged again"
_run "$OK"$'\nUNCLEAR RQADR-2: open'
assert_eq "fixture: judged open" ":1" "$_DESIGN_COV_OUTCOME:$_CALLS"
_run "should not be asked"
assert_eq "[DR1] the same issue: the open answer is kept, no call" "0" "$_CALLS"
_issue "$ISSUE"$'\n- **R3.** The holder is the ADR-064 run-status comment, edited in place.'
_run $'UNCLEAR RQADR-2: open'
assert_eq "[DR1] the issue's text changed: the questions are judged again" "1" "$_CALLS"
assert_contains "[DR1] ...against its new words" "$(cat "$_P_FILE")" "edited in place"
_issue "$ISSUE"

print_test_section "DR2: an unjudged carried question stays open"
rm -f "$artifact_dir/design-judged.json"
_run "$OK"
assert_eq "[DR2] no line for it after the re-ask: the try is not failed" "" "$_DESIGN_COV_OUTCOME"
assert_eq "[DR2] ...asked once again, then left" "2" "$_CALLS"
assert_eq "[DR2] ...no finding for design" "" "$FX"
assert_contains "[DR2] ...a note says it stays open, judged again" "${_DESIGN_COV_NOTES[*]-}" "UNCLEAR"
assert_contains "[DR2] ...on the next try" "${_DESIGN_COV_NOTES[*]-}" "next try"
_run $'UNCLEAR RQADR-2: open'
assert_eq "[DR2] the next try judges only the question: the others' answers were kept" "1::" "$_CALLS:$_DESIGN_COV_OUTCOME:${_DESIGN_COV_NOTES[*]-}"

print_test_section "DR3: an old-form design is named before design writes"
(
    _route_resolve_max_turns() { printf '9'; }
    _route_resolve_timeout()   { printf '60'; }
    route_to_model() { return 0; }
    apply_scope_redaction() { cp "$1" "$2"; }
    atomic_write() { cat - > "$1"; }
    art="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$art"
    printf '# Design\n\nUNCLEAR: RQADR-2 | which comment is this? | the ADR-064 one\n\n```acceptance\nDSHOLD-1[code]: x covers: RQADR-2\nWIRING: none\n```\n' > "$art/design.md"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/state/scope-manifest.md"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/state/events.jsonl" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/state"
    _design_stage_run_inner "$TEST_TEMP_DIR/state/scope-manifest.md" "$art/design.md" "$art" >/dev/null 2>&1 || true
)
PROMPT="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/state/artifacts/design-prompt.txt" 2>/dev/null || true)"
assert_contains "fixture: design refines the restored design" "$PROMPT" "YOUR LATEST DESIGN"
assert_contains "[DR3] the old-form line is named, to be rewritten in the one form" "$PROMPT" \
    "in the old form. Rewrite each in the one form above"
assert_contains "[DR3] ...the line itself" "$PROMPT" "- UNCLEAR: RQADR-2 | which comment is this? | the ADR-064 one"

print_test_section "DR4: only the check retires a question"
ROOT="$TEST_TEMP_DIR/frepo"; mkdir -p "$ROOT"
LAST_DIR="$TEST_TEMP_DIR/last"; mkdir -p "$LAST_DIR"
ACC=$'```acceptance\nDSHOLD-1[code]: the holder is shown covers: RQADR-2\n  When: a run claims the issue\n  Then: the comment names the holder\nWIRING: none\n```'
printf '# Design\n\nUNCLEAR: RQADR-2 | which comment is this? | the ADR-064 one\n\n%s\n' "$ACC" > "$LAST_DIR/design.md"
printf '# Design\n\n%s\n' "$ACC" > "$TEST_TEMP_DIR/new.md"
_checks() { _design_checks "$TEST_TEMP_DIR/new.md" "$ROOT" "" "$LAST_DIR/design.md" "$ISSUE"; FV="${_DESIGN_VIOLATIONS[*]-}"; FP=""; local v; for v in ${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}; do FP+="$(_dck_plain "$v")"$'\n'; done; }
_checks
assert_contains "[DR4] a question dropped with no check retiring it: refused" "$FV" "UNCLEAR_DROPPED RQADR-2"
assert_contains "[DR4] ...design told to keep it until its check retires it" "$FP" "only design's check retires a question"
stage_result_write "$LAST_DIR/design-verdict.json" unusable "the design fails 1 of its checks" \
    "$(jq -nc '{findings: [{n: 1, text: "UNCLEAR RQADR-2: the issue now answers it: the Terms say — the comment ADR-064 already posts [FIX IN DESIGN: ACCEPTED IF: the UNCLEAR RQADR-2 line is gone]"}]}')"
_checks
assert_eq "[DR4] the check retired it: it may go" "" "$FV"
rm -f "$LAST_DIR/design-verdict.json"

print_test_section "DR5/DR6: what design is told of a malformed line"
printf '# Design\n\nUNCLEAR RQADR-2 | "The holder is in the run-status comment" | a or b\n\n%s\n' "$ACC" > "$TEST_TEMP_DIR/new.md"
_checks
_last="${FP%$'\n'}"; _last="${_last: -1}"
assert_contains "fixture: the line is refused" "$FP" "an UNCLEAR line is not in its form"
assert_eq "[DR5] no stray ) after the form" ">" "$_last"
printf '# Design\n\nUNCLEAR RQADR-2 | "The holder" | a or b | ASSUMED: a\nUNCLEAR RQADR-2 | "run-status comment" | c or d | ASSUMED: c\n\n%s\n' "$ACC" > "$TEST_TEMP_DIR/new.md"
_checks
assert_contains "[DR6] a second question on one id: refused" "$FV" "UNCLEAR_MALFORMED"
assert_contains "[DR6] ...told to give each its own id" "$FP" "RQADR-2a and RQADR-2b"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
