#!/usr/bin/env bash
# tests/unit/issue-acceptance-per-item-test.sh — issue-acceptance keeps a
# verdict per requirement, as design's check keeps one per part (#2574 R3;
# ADR-072 §4 §5, amended 2026-11-20).
#
# Why: issue-acceptance kept one verdict for the whole change, with the
# answers to its findings in that verdict's fingerprint. Any change, or any
# new answer — or an answer no longer given — forced a full re-judge, which is
# where verdicts flip. Now each requirement is an item: a kept pass stands
# unless that requirement's inputs changed, an answer only has a kept refusal
# judged again (held to its finding), and only the changed items are asked, in
# one call.
#
# PI1 [change] the first call judges every requirement in one call, and keeps
#              a verdict for each
# PI2 [change] a file a refusal quoted changes: only that requirement is asked
#              again; the other's kept pass stands
# PI3 [change] build answers the refused requirement's finding, nothing
#              changed: only that requirement is asked, held to its finding
#              and the answer
# PI4 [change] the next try gives no answer and nothing changed: no call — each
#              kept verdict stands (the flip #1764 saw is not possible)
# PI5 [change] an answer to a finding about a requirement whose kept verdict is
#              a pass does not have it judged again
# PI6 [change] (review) a kept MET does not survive a change to a file no line
#              quoted: the change's content is in each requirement's fingerprint
# PI7 [change] (review) build answers RQCNFG-1's finding not mine — the test
#              must change, and its build-tests output carries it to
#              test-author: RQCNFG-1 is not judged again, its refusal stands,
#              noted as waiting; once test-author has run it is judged again,
#              held to the finding and the answer
# PI8 [change] (review) a kept MET judged again because the code moved: the
#              judge is shown its earlier verdict, and may refuse it only by
#              quoting a line the change added since; a refusal quoting a line
#              that was there leaves the MET standing (judge.held), one quoting
#              a line added since is taken
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "issue-acceptance keeps a verdict per requirement (#2574 R3)"
setup_test_env "issue-acceptance-per-item"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
(cd "$XR" && /usr/bin/git init -q && printf 'flag=1\n' > p.sh && /usr/bin/git add p.sh \
    && /usr/bin/git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$XR"

ISSUE_TEXT="Add a flag. Refuse a missing config file."
S="$TEST_TEMP_DIR/s"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"; printf '{}' > "$S/pipeline-state.json"
# Each input by its writer: the issue, intake's requirements, a design, a test run.
zb_test_issue_output "$IN" "$ISSUE_TEXT" >/dev/null
(
    # shellcheck source=../../plugins/agent/intake/plugin.sh
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
    route_to_model() {
        if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
        else printf 'REQUIREMENT: RQFLAG-1 Add a flag.\nREQUIREMENT: RQCNFG-1 Refuse a missing config file.\n'; fi
    }
    _intake_write_requirements "$IN" "$(jq -nc --arg b "$ISSUE_TEXT" '{title: "Add a flag", body: $b}')"
) >/dev/null 2>&1
printf '%s\n' '# Design' '```acceptance' 'DSFLAG-1[code]: a flag is accepted' 'DSCNFG-1[code]: a missing config is refused' 'WIRING: none' '```' > "$IN/design.md"
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' > "$IN/diff.patch"
zb_test_test_run_output "$IN" pass 1 0 >/dev/null
jq -n --arg i "$IN/intake-result.json" --arg r "$IN/requirements.json" --arg d "$IN/design.md" \
    --arg p "$IN/diff.patch" --arg t "$IN/test-results.json" \
    '{inputs: {a: $i, r: $r, b: $d, c: $p, d: $t}}' > "$S/stage-inputs.json"
export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"

# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
set +e
# The judge answers each requirement it is asked about (listed as `- <id>: `),
# and the reverse question when it is asked; CNFG is its line for RQCNFG-1.
_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
REFUSE='UNMET: [fix-code] RQCNFG-1 | WHY: a missing config file is not refused | ACCEPTED IF: a missing config file is refused | QUOTE: p.sh | flag=1'
CNFG="$REFUSE"
route_to_model() {
    local n r=""; n=$(( $(cat "$_N" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
    [[ "$2" == *$'\n- RQFLAG-1: '* ]] && r+="${FLAG:-MET: RQFLAG-1}"$'\n'
    # The files the call reads, as the router lists them.
    [[ -n "${OPENS:-}" && -n "${ZBUILD_ROUTER_OPENED_FILE:-}" ]] && printf '%s\n' "$OPENS" >> "$ZBUILD_ROUTER_OPENED_FILE"
    [[ "$2" == *$'\n- RQCNFG-1: '* ]] && r+="$CNFG"$'\n'
    [[ "$2" == *"Then answer the reverse question"* ]] && r+=$'UNASKED: none\n'
    printf '%s' "$r"
}
resolve_tier() { printf 'T2'; }
_ia() {
    rm -f "$_N" "$_P".*
    issue_acceptance_run issue-acceptance "$S/pipeline-state.json" >/dev/null 2>&1
    OUT="$(jq -r '.outcome // "MISSING"' "$A/issue-acceptance-result.json" 2>/dev/null || echo MISSING)"
    CALLS="$(cat "$_N" 2>/dev/null || echo 0)"
}
_asked() { grep -cE "^- $1: " "$_P.1" 2>/dev/null || true; }
_flat() { tr -s '[:space:]' ' ' < "$1" 2>/dev/null; }

print_test_section "PI1: every requirement, one call, a verdict each"
_ia
assert_eq "[PI1] one call" "1" "$CALLS"
assert_eq "[PI1] ...asked about RQFLAG-1" "1" "$(_asked RQFLAG-1)"
assert_eq "[PI1] ...and RQCNFG-1" "1" "$(_asked RQCNFG-1)"
assert_eq "[PI1] RQCNFG-1 is not met: fail" "fail" "$OUT"
_keys="$(jq -r 'keys | join(" ")' "$A/issue-acceptance-judged.json" 2>/dev/null)"
assert_contains "[PI1] a verdict is kept for RQFLAG-1" "$_keys" "RQFLAG-1"
assert_contains "[PI1] ...and one for RQCNFG-1" "$_keys" "RQCNFG-1"
FID="$(jq -r '.data.findings[] | select(.text | contains("RQCNFG-1")) | .id' "$A/issue-acceptance-result.json" 2>/dev/null | head -n 1)"
FTXT="$(jq -r '.data.findings[] | select(.text | contains("RQCNFG-1")) | .text' "$A/issue-acceptance-result.json" 2>/dev/null | head -n 1)"
assert_eq "[PI1] RQCNFG-1's finding has an id" "IAFND-" "${FID%%[0-9]*}"

print_test_section "PI2: a file the refusal quoted changes"
printf 'flag=1\nconfig_check=0\n' > "$XR/p.sh"
_ia
assert_eq "[PI2] one call" "1" "$CALLS"
assert_eq "[PI2] ...asked about RQCNFG-1, whose quoted file changed" "1" "$(_asked RQCNFG-1)"
assert_eq "[PI2] ...not about RQFLAG-1, whose kept pass stands" "0" "$(_asked RQFLAG-1)"
assert_eq "[PI2] still fail" "fail" "$OUT"

print_test_section "PI3: build answers RQCNFG-1's finding; nothing changed"
_bj="$(jq -nc --arg k "$FID" --arg t "$FTXT" '{($k): $t}')"
stage_result_write "$A/build-summary.json" pass "built" \
    "$(jq -nc --arg a "$FID: done — the run now exits when the config file is missing" --argjson f "$_bj" '{answers: [$a], answer_findings: $f}')" >/dev/null
CNFG='MET: RQCNFG-1'
_ia
assert_eq "[PI3] one call" "1" "$CALLS"
assert_eq "[PI3] ...asked about RQCNFG-1" "1" "$(_asked RQCNFG-1)"
assert_eq "[PI3] ...not about RQFLAG-1" "0" "$(_asked RQFLAG-1)"
assert_contains "[PI3] ...held to its earlier finding" "$(_flat "$_P.1")" "YOUR EARLIER FINDINGS, AND THE ANSWERS TO THEM"
assert_contains "[PI3] ...and build's answer" "$(_flat "$_P.1")" "answered: done — the run now exits when the config file is missing"
assert_eq "[PI3] both met: pass" "pass" "$OUT"

print_test_section "PI4: no answer, nothing changed"
stage_result_write "$A/build-summary.json" pass "built" '{}' >/dev/null
CNFG="$REFUSE"
_ia
assert_eq "[PI4] no call" "0" "$CALLS"
assert_eq "[PI4] the kept verdicts stand: pass" "pass" "$OUT"

print_test_section "PI5: an answer about a requirement whose kept verdict is a pass"
_old="The issue requires this and the change does not meet it: RQFLAG-1: no flag is read"
stage_result_write "$A/build-summary.json" pass "built" \
    "$(jq -nc --arg t "$_old" '{answers: ["IAFND-90: wrong — the flag is read in p.sh"], answer_findings: {"IAFND-90": $t}}')" >/dev/null
_ia
assert_eq "[PI5] no call: RQFLAG-1's kept pass stands" "0" "$CALLS"
assert_eq "[PI5] pass" "pass" "$OUT"

print_test_section "PI6: a change to a file no line quoted"
# The same file, other content: no name changes, and no line quoted it.
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' '+flag_parsed=0' > "$IN/diff.patch"
_ia
assert_eq "[PI6] one call" "1" "$CALLS"
assert_eq "[PI6] ...RQFLAG-1 judged again" "1" "$(_asked RQFLAG-1)"
assert_eq "[PI6] ...and RQCNFG-1" "1" "$(_asked RQCNFG-1)"

print_test_section "PI7: a requirement handed to test-author waits for it"
# shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
source "$REPO_ROOT/scripts/lib/stage-dispatch-mark.sh"
export ZBUILD_STATE_DIR="$S" ZBUILD_INPUTS_FLOW="design test-author build test issue-acceptance"
# A line added since RQCNFG-1 last passed, which breaks it (PI8's rule).
printf 'config_skip=1\n' >> "$XR/p.sh"
CNFG='UNMET: [fix-code] RQCNFG-1 | WHY: a missing config file is skipped | ACCEPTED IF: a missing config file is refused | QUOTE: p.sh | config_skip=1'
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' '+flag_parsed=1' > "$IN/diff.patch"
_ia
assert_eq "[PI7] setup: RQCNFG-1 refused" "fail" "$OUT"
FID="$(jq -r '.data.findings[] | select(.text | contains("RQCNFG-1")) | .id' "$A/issue-acceptance-result.json" | head -n 1)"
stage_dispatch_mark "$S/pipeline-state.json" test-author
touch -t 202001010000 "$(stage_dispatch_mark_path "$S" test-author)"
# Build's answer, by build's own writers: its build-tests output and its summary.
( # shellcheck source=../../plugins/agent/build/lib/answers.sh
  source "$REPO_ROOT/plugins/agent/build/lib/answers.sh"
  _ROUTE_LOOP_LAST_RESPONSE="ANSWER $FID: not mine — the test must change: tests/cfg-test.sh: it expects the old message"
  _build_write_test_findings "$A" ) >/dev/null 2>&1
stage_result_write "$A/build-summary.json" pass "built" \
    "$(jq -nc --arg a "$FID: not mine — the test must change: tests/cfg-test.sh: it expects the old message" '{answers: [$a]}')" >/dev/null
CNFG='MET: RQCNFG-1'
_ia
assert_eq "[PI7] RQCNFG-1 is not asked" "0" "$CALLS"
assert_eq "[PI7] ...its refusal stands" "fail" "$OUT"
assert_contains "[PI7] ...noted as waiting" "$(jq -r '(.data.notes // []) | join("|")' "$A/issue-acceptance-result.json")" "RQCNFG-1: handed to test-author, waiting"
stage_dispatch_mark "$S/pipeline-state.json" test-author
_ia
assert_eq "[PI7] test-author has run: RQCNFG-1 is asked" "1" "$(_asked RQCNFG-1)"
assert_contains "[PI7] ...held to the finding and the answer" "$(_flat "$_P.1")" "not mine — the test must change"
assert_eq "[PI7] ...and passes" "pass" "$OUT"

print_test_section "PI8: a kept MET is refused only on a line added since"
FLAG="MET: RQFLAG-1"; OPENS="$XR/p.sh"; CNFG='MET: RQCNFG-1'
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' '+flag_parsed=2' > "$IN/diff.patch"
_ia
assert_eq "[PI8] setup: both met, the call read p.sh" "pass" "$OUT"
OPENS=""
printf 'flag_unused=1\n' >> "$XR/p.sh"
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' '+flag_parsed=3' > "$IN/diff.patch"
FLAG='UNMET: [fix-code] RQFLAG-1 | WHY: the flag is not read | ACCEPTED IF: the flag is read | QUOTE: p.sh | flag=1'
: > "$ZBUILD_EVENTS_JSONL"
_ia
assert_eq "[PI8] RQFLAG-1 is asked again: the code moved" "1" "$(_asked RQFLAG-1)"
assert_contains "[PI8] ...shown its earlier verdict" "$(_flat "$_P.1")" "YOUR EARLIER VERDICTS ON PARTS YOU PASSED"
assert_eq "[PI8] a refusal quoting a line that was there: the MET stands" "pass" "$OUT"
assert_contains "[PI8] ...and judge.held records it" "$(cat "$ZBUILD_EVENTS_JSONL")" "judge.held"
printf 'flag_ignored=1\n' >> "$XR/p.sh"
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' '+flag_parsed=4' > "$IN/diff.patch"
FLAG='UNMET: [fix-code] RQFLAG-1 | WHY: the flag is now ignored | ACCEPTED IF: the flag is read | QUOTE: p.sh | flag_ignored=1'
_ia
assert_eq "[PI8] a refusal quoting a line added since: refused" "fail" "$OUT"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
