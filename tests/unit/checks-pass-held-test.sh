#!/usr/bin/env bash
# tests/unit/checks-pass-held-test.sh — design's check: a kept pass judged
# again because a file it read moved is refused only on a line added since
# (#2574 review; ADR-072 §4, amended 2026-11-20). Issue-acceptance
# (issue-acceptance-per-item-test.sh PI8) and the lenses (lens-per-item-test.sh
# LP11) are held the same way.
#
# P1 [change] the steps passed; a file the check read moves; the check refuses
#             them quoting their own words: the pass stands, and judge.held
#             records it
# P2 [guard]  the steps' own words change: they are judged afresh, and a
#             refusal is taken
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's check: a kept pass is refused only on a line added since (#2574)"
setup_test_env "checks-pass-held"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

( # shellcheck source=../../plugins/agent/design/plugin.sh
  source "$REPO_ROOT/plugins/agent/design/plugin.sh"
  _P_FILE="$TEST_TEMP_DIR/prompt.txt"; _CALLS="$TEST_TEMP_DIR/calls"
  REFUSE="Steps: contradicts | WHY: bypassing plugin_hook_call | ACCEPTED IF: the engine calls the hooks through the registry | QUOTE: Create core/claim/claim.sh: thin wiring bridge"
  STEPS_LINE="Steps: ok"
  route_to_model() {
      printf 'x\n' >> "$_CALLS"; printf '%s' "$2" > "$_P_FILE"
      [[ -n "${ZBUILD_ROUTER_OPENED_FILE:-}" ]] && printf '%s\n' "$XR/core/claim/lib.sh" >> "$ZBUILD_ROUTER_OPENED_FILE"
      printf '%s' $'RQCL-1: covered\nCLA-1: ok\n'"$STEPS_LINE"$'\nDecision: ok'
      return 0; }
  XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR/core/claim"
  ( cd "$XR" && git init -q && printf 'claim_take() { :; }\n' > core/claim/lib.sh && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
  export ZBUILD_REPO_ROOT="$XR" _DESIGN_BASE_DIR="$XR"
  export artifact_dir="$TEST_TEMP_DIR/art"; mkdir -p "$artifact_dir"
  D="$TEST_TEMP_DIR/design.md"
  _design() { cat > "$D" <<MD
# Design
## Decision
Claim through the coordinator.

\`\`\`steps
- Create core/claim/claim.sh: thin wiring bridge that adds zbuild:claimed$1 | areas: core/claim/claim.sh
\`\`\`
\`\`\`acceptance
CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1
  When: a run starts on an issue with no claimed label
  Then: the claimed label is on the issue
WIRING: core/pipeline/runner.sh
\`\`\`
MD
  }
  _design ""
  REQS='- RQCL-1: the run adds the claimed label before the first stage'
  _run() { : > "$_CALLS"; _design_coverage "$D" "$REQS" T2 ""
           printf '%s: findings=%s calls=%s\n' "$1" "$(_design_coverage_findings | grep -c . || true)" "$(grep -c x "$_CALLS" || true)"; }
  _run pass1
  printf '# a helper\n' >> "$XR/core/claim/lib.sh"
  STEPS_LINE="$REFUSE"; : > "$ZBUILD_EVENTS_JSONL"
  _run held
  cp "$_P_FILE" "$TEST_TEMP_DIR/held-prompt.txt"
  grep -c '"judge.held"' "$ZBUILD_EVENTS_JSONL" | sed 's/^/held_events=/'
  _design " through plugin_hook_call"
  _run fresh
) > "$TEST_TEMP_DIR/p.log" 2>&1
_l="$(cat "$TEST_TEMP_DIR/p.log")"
print_test_section "P1: a pass judged again because a file moved"
assert_contains "[P1] setup: the steps pass" "$_l" "pass1: findings=0 calls=1"
assert_contains "[P1] the file moved: judged again" "$_l" "held: findings=0 calls=1"
assert_contains "[P1] ...shown that it passed" "$(cat "$TEST_TEMP_DIR/held-prompt.txt" 2>/dev/null)" "YOUR EARLIER VERDICTS ON PARTS YOU PASSED"
assert_contains "[P1] ...the refusal quoting the steps' own words is not taken: judge.held" "$_l" "held_events=1"
print_test_section "P2: the steps' own words change"
assert_contains "[P2] judged afresh: the refusal is taken" "$_l" "fresh: findings=1 calls=1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
