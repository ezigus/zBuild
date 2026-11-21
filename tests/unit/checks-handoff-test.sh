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
# TH1 [change] test-author answers its check's finding on SPEC-1 not mine. In the
#              engine's order — its handoff output cleared as the dispatch
#              starts (stage_handoff_clear), then the tries, then the handoff
#              written after the last — SPEC-1 is not judged again on the next
#              try, its refusal standing: test-author's design output's topic
#              is taken by design, a stage of this run that runs before it; once
#              design has run it is judged again, held to the finding and the
#              answer
# TH2 [change] the cap counts waits, not writes: a second not mine while the
#              part waits leaves the count at 1 and the wait's start unchanged
# TH3 [change] a receiver is a stage that runs before the waiting stage in the
#              run: a stage after it is none
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
  export ZBUILD_STATE_DIR="$S" ZBUILD_INPUTS_FLOW="design test-author build test" ZBUILD_CURRENT_STAGE=test-author
  # shellcheck source=../../scripts/lib/stage-retry.sh
  source "$REPO_ROOT/scripts/lib/stage-retry.sh"
  # shellcheck source=../../core/plugin-registry/attempt-archive.sh
  source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh" 2>/dev/null
  _ta() { : > "$_CALLS"; : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 "$ART" >/dev/null 2>&1
          printf '%s: calls=%s findings=%s\n' "$1" "$(grep -c x "$_CALLS" || true)" "${#_TA_CORR_FINDINGS[@]}"
          cp "$_P_FILE" "$TEST_TEMP_DIR/ta-$1-prompt.txt"; }
  _TA_ANSWERS=(); _ta try1
  _ta_write_result "$ART" unusable "the check found 1" 1 "$(printf '%s\n' "${_TA_CORR_FINDINGS[@]}" | stage_findings_json "$ART" "$_TA_FCODE")" >/dev/null 2>&1
  FID="$(jq -r '.data.findings[0].id' "$ART/test-author-result.json")"
  stage_dispatch_mark "$S/pipeline-state.json" design
  touch -t 202001010000 "$(stage_dispatch_mark_path "$S" design)"
  # The next dispatch: its handoff output cleared first, as the engine does.
  stage_handoff_clear "$REPO_ROOT/plugins/agent/test-author" "$S/pipeline-state.json"
  echo "cleared=$([[ -e "$ART/test-author-design-result.json" ]] && echo no || echo yes)"
  _TA_ANSWERS=("$FID: not mine — the SPEC must name what a test can observe"); _ta waits
  _TA_ANSWERS=(); _ta waits2
  stage_dispatch_mark "$S/pipeline-state.json" design
  _REPLY='SPEC-1: ok'
  _TA_ANSWERS=(); _ta back
) > "$TEST_TEMP_DIR/th1.log" 2>&1
_l="$(cat "$TEST_TEMP_DIR/th1.log")"
assert_contains "[TH1] setup: try 1 refused SPEC-1" "$_l" "try1: calls=1 findings=1"
assert_contains "[TH1] setup: the dispatch cleared the handoff output first" "$_l" "cleared=yes"
assert_contains "[TH1] handed to design: not judged, its refusal standing" "$_l" "waits: calls=0 findings=1"
assert_contains "[TH1] ...nor on the next try" "$_l" "waits2: calls=0 findings=1"
assert_contains "[TH1] design has run: judged again, and passes" "$_l" "back: calls=1 findings=0"
assert_contains "[TH1] ...held to the finding and the answer" "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/ta-back-prompt.txt" 2>/dev/null)" "not mine — the SPEC must name what a test can observe"

print_test_section "TH2: the cap counts waits, not writes"
# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"
H="$TEST_TEMP_DIR/th2"; mkdir -p "$H/runtime/dispatched" "$H/a"
KF="$H/a/x-judged.json"
ZBUILD_STATE_DIR="$H" judge_handoff_put "$KF" step-1 test-author "not mine" "f"
touch -t 202001010000 "${KF%.json}-handed-step-1"; : > "$H/after"
ZBUILD_STATE_DIR="$H" judge_handoff_put "$KF" step-1 test-author "not mine again" "f"; _rc=$?
assert_eq "[TH2] a second not mine while it waits: taken, rc 0" "0" "$_rc"
assert_eq "[TH2] ...the count stays at 1" "1" "$(cat "${KF%.json}-handoffs-step-1")"
assert_eq "[TH2] ...and the wait's start is unchanged" "old" "$([[ "${KF%.json}-handed-step-1" -nt "$H/after" ]] && echo new || echo old)"

print_test_section "TH3: a receiver runs before the waiting stage"
_rcv=""
ZBUILD_INPUTS_FLOW="design build test-author" ZBUILD_CURRENT_STAGE=build \
    judge_handoff_own_receivers_v _rcv "$REPO_ROOT/plugins/agent/test-author/manifest.yaml"
assert_eq "[TH3] test-author's handoff topic is design's; design runs before build" "design" "$_rcv"
ZBUILD_INPUTS_FLOW="build design" ZBUILD_CURRENT_STAGE=build \
    judge_handoff_own_receivers_v _rcv "$REPO_ROOT/plugins/agent/test-author/manifest.yaml"
assert_eq "[TH3] design after build: no receiver" "" "$_rcv"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
