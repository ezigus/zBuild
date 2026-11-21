#!/usr/bin/env bash
# tests/unit/checks-handoff-test.sh — test-author's check waits on a SPEC it
# handed to design (#2574 R1 review; ADR-072 §5, amended 2026-11-20).
#
# Build's step check (plugins/agent/build/tests/build-step-handoff-test.sh),
# issue-acceptance (issue-acceptance-per-item-test.sh PI7) and the lenses
# (lens-per-item-test.sh LP9) wait on a part handed on; so does test-author's
# check. Design's check cannot: design has no output that carries a finding to
# another stage (ADR-072 §5, amended 2026-11-20).
#
# TH1 [change] test-author answers its check's finding on SPEC-1 not mine, and
#              its handoff output carries the finding to design: SPEC-1 is not
#              judged again, its refusal standing; once design has run it is
#              judged again, held to the finding and the answer
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "test-author's check waits on a SPEC handed to design (#2574)"
setup_test_env "checks-handoff"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

print_test_section "TH1: test-author's check"
( # shellcheck source=../../plugins/agent/test-author/plugin.sh
  source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
  # shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
  source "$REPO_ROOT/scripts/lib/stage-dispatch-mark.sh"
  _P_FILE="$TEST_TEMP_DIR/ta-prompt.txt"; _CALLS="$TEST_TEMP_DIR/ta-calls"
  route_to_model() {
      cat >/dev/null; printf 'x\n' >> "$_CALLS"; printf '%s' "$2" >> "$_P_FILE"
      printf '%s' "$_REPLY"; return 0; }
  _REPLY='SPEC-1 Then: missing | WHY: one case of several | ACCEPTED IF: the test asserts thing 1 holds for every case | QUOTE: thing 1 holds for every case'
  R="$TEST_TEMP_DIR/ta-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/ta-design.md"
  printf '# Design\n```acceptance\nSPEC-1[code]: thing 1 holds for every case\nWIRING: none\n```\n' > "$D"
  printf 'assert_eq "[SPEC-1] thing 1 holds" "1" "$got"\n' > "$R/tests/acc-test.sh"
  S="$TEST_TEMP_DIR/state"; ART="$S/artifacts"; mkdir -p "$ART"; printf '{}' > "$S/pipeline-state.json"
  export ZBUILD_STATE_DIR="$S" ZBUILD_INPUTS_FLOW="design test-author build test"
  _ta() { : > "$_CALLS"; : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 "$ART" >/dev/null 2>&1
          printf '%s: calls=%s findings=%s\n' "$1" "$(grep -c x "$_CALLS" || true)" "${#_TA_CORR_FINDINGS[@]}"
          cp "$_P_FILE" "$TEST_TEMP_DIR/ta-$1-prompt.txt"; }
  _TA_ANSWERS=(); _ta try1
  _ta_write_result "$ART" unusable "the check found 1" 1 "$(printf '%s\n' "${_TA_CORR_FINDINGS[@]}" | stage_findings_json "$ART" "$_TA_FCODE")" >/dev/null 2>&1
  FID="$(jq -r '.data.findings[0].id' "$ART/test-author-result.json")"
  # The engine's handoff writes the finding to test-author's design output.
  stage_findings_add "$ART/test-author-design-result.json" \
      "[{\"text\":\"test-author changed nothing for $FID and answered: not mine — the SPEC must name what a test can observe\"}]" "$_TA_FCODE"
  stage_dispatch_mark "$S/pipeline-state.json" design
  touch -t 202001010000 "$(stage_dispatch_mark_path "$S" design)"
  _TA_ANSWERS=("$FID: not mine — the SPEC must name what a test can observe"); _ta waits
  _TA_ANSWERS=(); _ta waits2
  stage_dispatch_mark "$S/pipeline-state.json" design
  _REPLY='SPEC-1: ok'
  _TA_ANSWERS=(); _ta back ) > "$TEST_TEMP_DIR/th1.log" 2>&1
_l="$(cat "$TEST_TEMP_DIR/th1.log")"
assert_contains "[TH1] setup: try 1 refused SPEC-1" "$_l" "try1: calls=1 findings=1"
assert_contains "[TH1] handed to design: not judged, its refusal standing" "$_l" "waits: calls=0 findings=1"
assert_contains "[TH1] ...nor on the next try" "$_l" "waits2: calls=0 findings=1"
assert_contains "[TH1] design has run: judged again, and passes" "$_l" "back: calls=1 findings=0"
assert_contains "[TH1] ...held to the finding and the answer" "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/ta-back-prompt.txt" 2>/dev/null)" "not mine — the SPEC must name what a test can observe"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
