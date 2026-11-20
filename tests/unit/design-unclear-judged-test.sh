#!/usr/bin/env bash
# tests/unit/design-unclear-judged-test.sh — design's check judges every
# question the design carries; design's form check holds each to the one form
# (#2571, ADR-069 §12, ADR-073 §5).
#
# Why: on #1764 design's `UNCLEAR: RQADR-2 | "the holder is in the run-status
# comment" — which comment is this? | …` rode along for days through every
# design: design refines its previous design, so the line was carried forward,
# and design's check left UNCLEAR lines out of the parts it judged. The issue's
# Terms answer it: "Run-status comment: the comment ADR-064 already posts and
# edits for every run (`scripts/lib/run-status-comment.sh`). Not a new comment."
#
# DU1 [change] the check is shown each carried question and the three answers
# DU2 [change] #1764's case: the check answers answered, quoting the Terms, and
#              design gets a finding to drop the question
# DU3 [change] an open question is no finding
# DU4 [change] a question with no answer line is asked again, naming it; an
#              answer whose quote is not in the issue is asked again; still
#              unjudged after that, it stays open and the try is not failed
#              (review on #2571; design-unclear-review-test.sh DR2)
# DU5 [change] the answer is kept like the other items: the same design asks
#              nothing again, and the finding still stands
# DU6 [change] design's form check: a line with no assumption, or whose quote is
#              not in the issue, is refused, saying the one form; a good line
#              passes
# DU7 [change] design's writer is told the one form and the rule
# DU8 [change] a question in the one form, with an ASSUMED: wrapped onto a line
#              of its own, is not one of the design's decisions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's check judges the questions it carries (#2571)"
setup_test_env "design-unclear-judged"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

_P_FILE="$TEST_TEMP_DIR/prompt.txt"; _CALLS=0
route_to_model() { _CALLS=$((_CALLS + 1)); printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
export artifact_dir="$TEST_TEMP_DIR/art"; mkdir -p "$artifact_dir"
ISSUE='## Terms
- **Run-status comment:** the comment ADR-064 already posts and edits for every run (`scripts/lib/run-status-comment.sh`). Not a new comment.

## Required behavior
- **R2.** The holder is in the run-status comment.'
# The issue as intake gives it: data.issue_text of its result.
stage_result_write "$artifact_dir/intake-result.json" pass "took in the issue" \
    "$(jq -nc --arg t "$ISSUE" '{goal_len: ($t | length), issue_text: $t}')"

D="$TEST_TEMP_DIR/design-draft.md"
cat > "$D" <<'MD'
# Design

UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | the ADR-064 one

```acceptance
DSHOLD-1[code]: the holder is shown in the run-status comment covers: RQADR-2
  When: a run claims the issue
  Then: the run-status comment names the holder
WIRING: none
```
MD
REQS='- RQADR-2: The holder is in the run-status comment.'
OK=$'RQADR-2: covered\nDSHOLD-1: ok'
ANSWERED='UNCLEAR RQADR-2: answered | WHY: the Terms say which comment it is | QUOTE: the comment ADR-064 already posts and edits for every run'
_run() { : > "$_P_FILE"; _CALLS=0; _REPLY="$1"; ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2 "" "" ""; FX="$(_design_coverage_findings)"; }

print_test_section "DU1/DU2: #1764's carried question"
_run "$OK"$'\n'"$ANSWERED"
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
assert_contains "[DU1] the check is shown the carried question" "$_P" \
    'UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | the ADR-064 one'
assert_contains "[DU1] ...and the answer forms" "$_P" "UNCLEAR <id>: answered | WHY: <how the issue answers it> | QUOTE: <the issue's words that answer it>"
assert_contains "[DU1] ...and the issue's words to judge it against" "$_P" "the comment ADR-064 already posts and edits for every run"
assert_eq "[DU2] the answer is read" "" "$_DESIGN_COV_OUTCOME"
assert_contains "[DU2] design gets a finding to drop the question" "$FX" \
    "UNCLEAR RQADR-2: the issue now answers it: the Terms say which comment it is — the comment ADR-064 already posts and edits for every run [FIX IN DESIGN: ACCEPTED IF: the UNCLEAR RQADR-2 line is gone"

print_test_section "DU3: an open question"
rm -f "$artifact_dir/design-judged.json"
_run "$OK"$'\nUNCLEAR RQADR-2: open'
assert_eq "[DU3] read" "" "$_DESIGN_COV_OUTCOME"
assert_eq "[DU3] no finding" "" "$FX"

print_test_section "DU4: asked again"
rm -f "$artifact_dir/design-judged.json"
_run "$OK"
assert_eq "[DU4] no line for the question: it stays open, the try not failed" ":" "$_DESIGN_COV_OUTCOME:$FX"
assert_contains "[DU4] ...asked again, naming it" "$(cat "$_P_FILE")" "UNCLEAR RQADR-2"
rm -f "$artifact_dir/design-judged.json"
_run "$OK"$'\nUNCLEAR RQADR-2: answered | WHY: w | QUOTE: a label holds it'
assert_eq "[DU4] an answer quoting words not in the issue: not used, the question stays open" ":" "$_DESIGN_COV_OUTCOME:$FX"
assert_contains "[DU4] ...the re-ask says so" "$(cat "$_P_FILE")" "not in the issue"

print_test_section "DU5: kept like the other items"
rm -f "$artifact_dir/design-judged.json"
_run "$OK"$'\n'"$ANSWERED"
_run "should not be asked"
assert_eq "[DU5] the same design: no call" "0" "$_CALLS"
assert_contains "[DU5] ...the kept answer's finding stands" "$FX" "UNCLEAR RQADR-2: the issue now answers it"

print_test_section "DU6: design's form check"
ROOT="$TEST_TEMP_DIR/frepo"; mkdir -p "$ROOT"
BASE_D="$TEST_TEMP_DIR/base.md"
printf '# Design\n\n```acceptance\nDSHOLD-1[code]: the holder is shown covers: RQADR-2\n  When: a run claims the issue\n  Then: the comment names the holder\nWIRING: none\n```\n' > "$BASE_D"
_form() { { cat "$BASE_D"; printf '\n%s\n' "$1"; } > "$TEST_TEMP_DIR/f.md"; _design_checks "$TEST_TEMP_DIR/f.md" "$ROOT" ""; FV="${_DESIGN_VIOLATIONS[*]-}"; FP=""; local v; for v in ${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}; do FP+="$(_dck_plain "$v")"$'\n'; done; }
_form 'UNCLEAR RQADR-2 | "The holder is in the run-status comment" | a new one, or the ADR-064 one | ASSUMED: the ADR-064 one'
assert_eq "[DU6] a line in the one form, quoting the issue, passes" "" "$FV"
_form 'UNCLEAR RQADR-2 | "The holder is in the run-status comment" | a new one, or the ADR-064 one'
assert_contains "[DU6] no assumption: refused" "$FV" "UNCLEAR_MALFORMED"
assert_contains "[DU6] ...design told the one form" "$FP" 'UNCLEAR <id> | "<the issue'"'"'s unclear words, quoted>" | <the readings> | ASSUMED: <the reading chosen and acted on>'
_form 'UNCLEAR RQADR-2 | "the holder lives in a label" | a or b | ASSUMED: a'
assert_contains "[DU6] a quote not in the issue: refused" "$FV" "UNCLEAR_MALFORMED"
assert_contains "[DU6] ...saying so" "$FP" "not in the issue"

print_test_section "DU7: design's writer is told the one form"
(
    _route_resolve_max_turns() { printf '9'; }
    _route_resolve_timeout()   { printf '60'; }
    route_to_model() { return 0; }
    apply_scope_redaction() { cp "$1" "$2"; }
    atomic_write() { cat - > "$1"; }
    art="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$art"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/state/scope-manifest.md"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/state/events.jsonl" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/state"
    _design_stage_run_inner "$TEST_TEMP_DIR/state/scope-manifest.md" "$art/design.md" "$art" >/dev/null 2>&1 || true
)
PROMPT="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/state/artifacts/design-prompt.txt" 2>/dev/null || true)"
assert_contains "fixture: design's prompt was written" "$PROMPT" "acceptance"
assert_contains "[DU7] the one form" "$PROMPT" 'UNCLEAR <id> | "<the issue'"'"'s unclear words, quoted>" | <the readings> | ASSUMED: <the reading chosen and acted on>'
assert_contains "[DU7] quote the issue's words; they are checked" "$PROMPT" "copied from the issue as they are: they are checked against it"
assert_contains "[DU7] pick one reading and act on it" "$PROMPT" "Pick one reading and act on it"
assert_contains "[DU7] about what the issue means, never how to build it" "$PROMPT" "about what the issue means, never about how to build it"
assert_contains "[DU7] never instead of deciding" "$PROMPT" "never takes the place of a decision you can make yourself"

print_test_section "DU8: a question is no decision"
DD="$TEST_TEMP_DIR/decisions.md"
printf '# Design\n\n## Decision\nThe holder is shown in the comment.\n\nUNCLEAR RQADR-2 | "The holder is in the run-status comment" | a new one,\nor the ADR-064 one\nASSUMED: the ADR-064 one\n' > "$DD"
_dv=""; design_decisions_prose_v _dv "$DD" 0
assert_contains "[DU8] the decision is read" "$_dv" "The holder is shown in the comment."
assert_eq "[DU8] ...the question and its wrapped lines are not" "0" "$(grep -c -e 'UNCLEAR' -e 'ADR-064 one' <<< "$_dv" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
