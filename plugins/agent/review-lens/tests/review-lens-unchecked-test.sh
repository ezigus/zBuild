#!/usr/bin/env bash
# Tests: a lens finding that cannot be checked costs only itself (#2598 R2,
# ADR-038, ADR-072 §3). #2532 run 45231040380: red-team's 8 findings were all
# dropped, and the run stopped, for one finding whose quote was not in its file.
#
#   U1 [change]: a finding whose quote is not found is asked about again on its
#                own; still not found, the other findings are kept, the lens
#                fails, and the result says which finding could not be checked
#   U2 [change]: a finding the re-ask corrects joins the others: none unchecked
#   U3 [change]: an unchecked finding fails the lens even when it is low and
#                the others would pass it, and its routed finding blocks
#   U4 [guard] : an answer with no usable finding at all, twice, is unusable
#   U5 [change]: a re-ask answered with only the FINDING block (no SCORE) is
#                merged: the corrected finding counts (review on #2598)
#   U6 [change]: an unchecked fix: issue finding is an ordinary failure, never
#                misconfigured
#   U7 [guard] : a lens whose template lists no fail_on never fails, unchecked
#                or not
#   U8 [change]: the knock-down check is not shown an unchecked finding
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a lens finding that cannot be checked costs only itself (#2598)"
setup_test_env "review-lens-unchecked"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
zb_test_lens_jobs u1 u2 u3 u4 u5 u6 u7 u8

_RQ="$TEST_TEMP_DIR/calls"
_reset() { rm -rf "$_RQ"; mkdir -p "$_RQ"; printf '0' > "$_RQ/n"; local i=0 r; for r in "$@"; do i=$((i + 1)); printf '%s' "$r" > "$_RQ/r$i"; done; }
_calls() { cat "$_RQ/n"; }
# shellcheck disable=SC2329  # invoked by the sourced plugin
route_to_model() { if [[ "$2" == *"Your job: for each finding below, try to show that it cannot happen"* ]]; then printf '%s' "$2" >> "$_RQ/check-prompts"; fi
    zb_test_lens_check_answer "$2" && return 0
    local n; n=$(( $(cat "$_RQ/n") + 1 )); printf '%s' "$n" > "$_RQ/n"; printf '%s' "$2" > "$_RQ/prompt-$n.txt"
    cat "$_RQ/r$n" 2>/dev/null
}
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/core"; printf 'one line\ntwo line\nthree line\n' > "$R/core/x.sh"
export ZBUILD_REPO_ROOT="$R"
artifact_dir="$TEST_TEMP_DIR/artifacts"; mkdir -p "$artifact_dir"
scope="$TEST_TEMP_DIR/scope.md"; printf '+ core/\n' > "$scope"
evidence="$artifact_dir/diff.patch"; printf 'diff --git a/core/x.sh b/core/x.sh\n+one line\n' > "$evidence"
_f() {  # <severity> <quote> <message>
    printf 'FINDING\nseverity: %s\ncategory: logic\nfix: code\nintroduced: yes\nquote: core/x.sh | %s\nmessage: %s\ntrigger: a normal run\naccepted if: it is fixed\n' "$1" "$2" "$3"
}
FAIL_ON="medium high critical"
_run() { : > "$ZBUILD_EVENTS_JSONL"
    ( cd "$R" && ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID="$1" _TPL_STAGE_FAIL_ON_review_lenses="$FAIL_ON" \
        _review_lens_run_inner "$1" "$scope" "$evidence" "$artifact_dir/lens-$1.json" "$artifact_dir" ) >/dev/null 2>&1; }
_msgs() { jq -r '[.findings[] | .message] | join(",")' "$artifact_dir/lens-$1.json" 2>/dev/null; }

print_test_section "U1: one finding still not found"
_reset "SCORE: 4"$'\n'"$(_f medium 'one line' first)"$'\n'"$(_f medium 'not in the file' second)"$'\n'"$(_f medium 'three line' third)" \
       "SCORE: 4"$'\n'"$(_f medium 'still not in it' second)"
_run u1
assert_eq "[U1] the lens was asked twice" "2" "$(_calls)"
assert_contains "[U1] the re-ask is about finding 2 alone" "$(cat "$_RQ/prompt-2.txt" 2>/dev/null)" "Answer again only for finding 2"
assert_eq "[U1] the lens fails" "fail" "$(jq -r '.outcome' "$artifact_dir/lens-u1.json" 2>/dev/null)"
assert_eq "[U1] the other findings are kept, with the one that could not be checked" "first,second,third" "$(_msgs u1)"
assert_eq "[U1] ...which is marked unchecked" "1" "$(jq '[.findings[] | select(.unchecked)] | length' "$artifact_dir/lens-u1.json" 2>/dev/null)"
assert_contains "[U1] ...saying why" "$(jq -r '.findings[1].unchecked // ""' "$artifact_dir/lens-u1.json" 2>/dev/null)" "is not in core/x.sh"
assert_contains "[U1] the routed finding says it could not be checked" "$(cat "$artifact_dir"/lens-u1-code-result.json 2>/dev/null)" "could not be checked"

print_test_section "U2: the re-ask corrects it"
_reset "SCORE: 4"$'\n'"$(_f low 'one line' first)"$'\n'"$(_f low 'not in the file' second)" \
       "SCORE: 4"$'\n'"$(_f low 'two line' second)"
_run u2
assert_eq "[U2] both findings" "first,second" "$(_msgs u2)"
assert_eq "[U2] none unchecked" "0" "$(jq '[.findings[] | select(.unchecked)] | length' "$artifact_dir/lens-u2.json" 2>/dev/null)"
assert_eq "[U2] low findings: the lens passes" "pass" "$(jq -r '.outcome' "$artifact_dir/lens-u2.json" 2>/dev/null)"

print_test_section "U3: a low unchecked finding fails the lens"
_reset "SCORE: 8"$'\n'"$(_f low 'one line' first)"$'\n'"$(_f low 'nowhere' second)" \
       "SCORE: 8"$'\n'"$(_f low 'nowhere either' second)"
_run u3
assert_eq "[U3] the lens fails on the unchecked finding" "fail" "$(jq -r '.outcome' "$artifact_dir/lens-u3.json" 2>/dev/null)"
assert_eq "[U3] ...its routed finding blocks" "true" "$(jq -r '[.data.findings[] | select(.text | contains("could not be checked")) | .blocking] | first // empty' "$artifact_dir/lens-u3-code-result.json" 2>/dev/null)"

print_test_section "U4: nothing usable"
_reset "not an answer" "still not one"
_run u4
assert_eq "[U4] unusable" "unusable" "$(jq -r '.outcome' "$artifact_dir/lens-u4.json" 2>/dev/null)"

print_test_section "U5: a re-ask with no SCORE line"
_reset "SCORE: 4"$'\n'"$(_f low 'one line' first)"$'\n'"$(_f low 'not in the file' second)" "$(_f low 'two line' second)"
_run u5
assert_eq "[U5] the corrected finding counts: none unchecked" "0" "$(jq '[.findings[] | select(.unchecked)] | length' "$artifact_dir/lens-u5.json" 2>/dev/null)"
assert_eq "[U5] ...both findings" "first,second" "$(_msgs u5)"

print_test_section "U6: an unchecked fix: issue finding"
_fi() { _f low "$1" "$2" | sed 's/^fix: code$/fix: issue/; s/^introduced: yes$/introduced: no/'; }
_reset "SCORE: 4"$'\n'"$(_f low 'one line' first)"$'\n'"$(_fi 'nowhere' second)" "$(_fi 'nowhere again' second)"
_run u6
assert_eq "[U6] an ordinary failure, not misconfigured" "fail" "$(jq -r '.outcome' "$artifact_dir/lens-u6.json" 2>/dev/null)"

print_test_section "U7: no fail_on"
FAIL_ON=""
_reset "SCORE: 4"$'\n'"$(_f low 'one line' first)"$'\n'"$(_f low 'nowhere' second)" "$(_f low 'nowhere again' second)"
_run u7
assert_eq "[U7] the lens never fails" "pass" "$(jq -r '.outcome' "$artifact_dir/lens-u7.json" 2>/dev/null)"
FAIL_ON="medium high critical"

print_test_section "U8: the knock-down check"
rm -f "$_RQ/check-prompts"
_reset "SCORE: 4"$'\n'"$(_f medium 'one line' first)"$'\n'"$(_f medium 'nowhere' UNCHECKED-ONE)" "$(_f medium 'nowhere again' UNCHECKED-ONE)"
_run u8
assert_contains "[U8] setup: the check ran" "$(cat "$_RQ/check-prompts" 2>/dev/null)" "first"
_cp="$(cat "$_RQ/check-prompts" 2>/dev/null)"
if [[ "$_cp" == *UNCHECKED-ONE* ]]; then assert_fail "[U8] ...and was not shown the unchecked finding" "it was"; else assert_pass "[U8] ...and was not shown the unchecked finding"; fi
assert_contains "[U8] the unchecked finding is still in the result" "$(_msgs u8)" "UNCHECKED-ONE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
