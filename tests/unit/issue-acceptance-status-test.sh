#!/usr/bin/env bash
# tests/unit/issue-acceptance-status-test.sh — issue-acceptance reads each
# requirement by its status, and says when it is not sure (#2304, ADR-069 §7).
#
# Why: a requirement marked "needs work (no code)" or "already done" is never
# run against the old code, so nothing mechanical checks it. issue-acceptance is
# the one place that does. It used to receive the raw acceptance block — tags
# like [done] that mean nothing to a reader — and could only answer pass or fail,
# so a judge that could not tell guessed.
#
# I1 [code] the judge reads every requirement with its status in plain words: a
#           code one says its test failed on the old code and passes now; a
#           no-code one says nothing checked it mechanically; a done one says
#           design claims the code already does it, names its evidence, and shows
#           a short excerpt of the cited file as committed (HEAD), cleaned of
#           terminal colour codes. No raw [code]/[no-code]/[done] tag reaches it.
# I2 [code] the judge may say it is not sure about named requirements: the result
#           is a fail, data.unsure lists them, each is a numbered finding saying
#           what is unresolved and what would settle it (never who must check it,
#           #2330), and issue_acceptance.unsure is emitted and declared in the
#           manifest.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "issue-acceptance: requirements by status, and 'not sure' (#2304)"
setup_test_env "issue-acceptance-status"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
set +e

_IA_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_IA_ANSWER=""
route_to_model() { printf '%s' "$2" > "$_IA_PROMPT"; printf '%s\n' "$_IA_ANSWER"; return 0; }
resolve_tier() { printf 'T2'; }

# A repository whose committed file differs from the working copy: the excerpt
# must come from HEAD. Line 50 carries a colour code the cleaner must strip.
_R="$TEST_TEMP_DIR/repo"; mkdir -p "$_R/scripts"
for _i in $(seq 1 100); do
    if [[ $_i -eq 50 ]]; then printf 'COMMITTED_LINE_50 \033[31mred\033[0m\n'; else printf 'line %d\n' "$_i"; fi
done > "$_R/scripts/x.sh"
(cd "$_R" && /usr/bin/git init -q && /usr/bin/git add -A \
    && /usr/bin/git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
printf 'WORKING_COPY_ONLY\n' > "$_R/scripts/x.sh"
export ZBUILD_REPO_ROOT="$_R"

_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; local _in="$_S/inputs"
    mkdir -p "$_A" "$_in"
    printf '{}' > "$_S/pipeline-state.json"
    printf 'Add the flag. Document it. Keep the parser.\n' > "$_in/issue.md"
    printf '%s\n' '# Design' '```acceptance' \
        'SPEC-1[code]: the flag is accepted' \
        'SPEC-2[no-code]: the flag is documented' \
        'SPEC-3[done]: the parser already reads flags evidence: scripts/x.sh:50' \
        'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_in/design.md"
    printf 'diff --git a/p.sh b/p.sh\n+flag=1\n' > "$_in/diff.patch"
    printf '{"result_contract":2,"verdict":"pass"}\n' > "$_in/test-results.json"
    jq -n --arg i "$_in/issue.md" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
        '{inputs: {intake_goal: $i, design: $d, diff_patch: $p, test_results: $t}}' > "$_S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A"
}
_res() { jq -r "$1" "$_A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }
_run() { : > "$_IA_PROMPT"; issue_acceptance_run "issue-acceptance" "$_S/pipeline-state.json" >/dev/null 2>&1; }

print_test_section "I1: each requirement in plain words, with its status"
_setup i1
_IA_ANSWER=$'VERDICT: pass\nREASON: all met'
_run
_p="$(cat "$_IA_PROMPT")"
_p1="$(tr -s '[:space:]' ' ' <<< "$_p")"
assert_contains "[I1] a code requirement: its test failed on the old code and passes now" "$_p1" \
    "needs work (code) — its test failed on the old code and passes now"
assert_contains "[I1] a no-code requirement: nothing checked it, judge it yourself" "$_p1" \
    "needs work (no code) — nothing checked it mechanically; judge it yourself, and say whether its tests would catch it broken"
assert_contains "[I1] a done requirement: design claims it, check the claim" "$_p1" \
    "already done — design says the code already does this; check the claim"
assert_contains "[I1] the requirement's own words reach the judge" "$_p1" "the parser already reads flags"
assert_contains "[I1] the done requirement's evidence is named" "$_p1" "scripts/x.sh:50"
assert_contains "[I1] the excerpt shows the cited line as committed (HEAD)" "$_p" "COMMITTED_LINE_50"
assert_eq "[I1] the excerpt is not the working copy" "0" "$(grep -c 'WORKING_COPY_ONLY' <<< "$_p" || true)"
assert_contains "[I1] the excerpt includes lines near the cited one" "$_p" "line 45"
assert_eq "[I1] the excerpt is bounded: a line far from the cited one is left out" "0" \
    "$(grep -cE '(^|[^0-9])line 20($|[^0-9])' <<< "$_p" || true)"
assert_eq "[I1] the excerpt is cleaned (no terminal colour codes)" "0" \
    "$(grep -c $'\033' <<< "$_p" || true)"
for _tag in '[code]' '[no-code]' '[done]'; do
    assert_eq "[I1] no raw $_tag tag reaches the judge" "0" "$(grep -cF "$_tag" <<< "$_p" || true)"
done

print_test_section "I2: not sure → fail, data.unsure, a finding saying what would settle it, an event"
_setup i2
_IA_ANSWER=$'VERDICT: unsure\nREASON: cannot tell whether the docs cover the flag\nUNSURE: SPEC-2 the flag is documented'
: > "$ZBUILD_EVENTS_JSONL"
_run; _rc=$?
assert_eq "[I2] rc=0 (the verdict is in the artifact)" "0" "$_rc"
assert_eq "[I2] verdict=fail" "fail" "$(_res .verdict)"
assert_eq "[I2] data.unsure lists the requirement" "SPEC-2 the flag is documented" "$(_res '.data.unsure[0]')"
assert_contains "[I2] a numbered finding says what would settle it (#2330)" \
    "$(_res '.data.findings[0].text')" "What would settle it:"
_f2="$(_res '.data.findings[0].text') $(cat "$_A/issue-acceptance-summary.md" 2>/dev/null)"
assert_eq "[I2] ...and never says who must check it: no 'a person' or 'human' (#2330)" "0" \
    "$(grep -ciE 'a person|human' <<< "$_f2" || true)"
assert_contains "[I2] ...naming the requirement" "$(_res '.data.findings[0].text')" "SPEC-2 the flag is documented"
assert_contains "[I2] issue_acceptance.unsure is emitted" "$(cat "$ZBUILD_EVENTS_JSONL")" "issue_acceptance.unsure"
assert_contains "[I2] the manifest declares the event" "$(cat "$PLUGIN_DIR/manifest.yaml")" "- issue_acceptance.unsure"
_p2="$(tr -s '[:space:]' ' ' <<< "$(cat "$_IA_PROMPT")")"
assert_contains "[I2] the prompt offers the 'not sure' answer" "$_p2" "VERDICT: pass | fail | unsure"
assert_contains "[I2] the prompt says how to name what it is not sure of" "$_p2" "UNSURE:"

_setup i2b
_IA_ANSWER=$'VERDICT: pass\nREASON: all met\nUNSURE: none'
_run
assert_eq "[I2] 'UNSURE: none' on a pass stays a pass" "pass" "$(_res .verdict)"
assert_eq "[I2] ...with nothing listed as unsure" "0" "$(_res '.data.unsure | length')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
