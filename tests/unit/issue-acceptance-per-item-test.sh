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
    [[ "$2" == *$'\n- RQFLAG-1: '* ]] && r+=$'MET: RQFLAG-1\n'
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
