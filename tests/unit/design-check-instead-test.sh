#!/usr/bin/env bash
# tests/unit/design-check-instead-test.sh — a refused SPEC part names what a
# test could observe instead, and a requirement nothing could observe stops
# the run for the issue's owner (#2565, ADR-073 §5).
#
# Why: on #1764 runs 43959139598 and 44090911022 design's check refused every
# wording of DSCLA-10 ("what a file contains", "how a test checks") without
# saying what would be accepted; design flipped wordings until it ran out of
# tries, though "the event is emitted with no unknown-event warning" was there.
#
# #2569 (ADR-073 §5): INSTEAD became ACCEPTED IF, which every refusal carries;
# an old INSTEAD is still read as ACCEPTED IF.
# I1 [change] the check's prompt asks, on an untestable or how line, what a
#             test could observe instead (its ACCEPTED IF), and gives a
#             requirement `none`
# I2 [change] `<id> And: untestable | WHY | ACCEPTED IF | QUOTE` is read:
#             design's finding carries what a test could observe instead; an
#             old INSTEAD is read the same
# I3 [change] an untestable or how line with no ACCEPTED IF cannot be used,
#             and the re-ask says so
# I6 [change] (review) ACCEPTED IF written bold is read as ACCEPTED IF
# I4 [change] `<req>: none | WHY | ACCEPTED IF | QUOTE` is read, not refused
# I5 [change] a requirement answered none stops design `misconfigured`, its
#             reason naming the requirement and why, for the issue's owner
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a refused part names what would be accepted; none stops the run (#2565)"
setup_test_env "design-check-instead"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# ── I1–I4: the check's answer, read ──────────────────────────────────────────
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
  _P_FILE="$TEST_TEMP_DIR/prompt.txt"
  route_to_model() { printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }
  XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"; export _DESIGN_BASE_DIR="$XR"
  D="$TEST_TEMP_DIR/design.md"
  cat > "$D" <<'MD'
# Design
```acceptance
CLA-10[code]: a refused claim is reported covers: RQCL-1
  When: a run starts on an issue another runner holds
  Then: the run stops
  And: pipeline.refused.claimed is registered in config/event-schema.json
WIRING: core/pipeline/runner.sh
```
MD
  REQS='- RQCL-1: a refused claim is reported as an event'
  _run() { : > "$_P_FILE"; _REPLY="$1"; ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2; FX="$(_design_coverage_findings)"; }

  print_test_section "I1: the prompt asks what would be accepted"
  _run $'RQCL-1: covered\nCLA-10: ok'
  _P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  assert_contains "[I1] an untestable or how line names what a test could observe instead" "$_P" \
      "For an untestable or a how line, ACCEPTED IF is what a test could observe after the When for the same requirement."
  assert_contains "[I1] ...and a requirement nothing could observe is none" "$_P" \
      "<requirement id>: none | WHY: <why nothing a test could observe after the change would show it met> | ACCEPTED IF: <what the requirement must say for a test to observe it met> | QUOTE: <the requirement's own words>"

  print_test_section "I2/I3: ACCEPTED IF reaches design, and is required"
  _run $'RQCL-1: covered\nCLA-10 And: untestable | WHY: it is what a file contains | ACCEPTED IF: pipeline.refused.claimed is emitted with no unknown-event warning | QUOTE: is registered in config/event-schema.json'
  assert_eq "[I2] the untestable line with ACCEPTED IF is used" "" "$_DESIGN_COV_OUTCOME"
  assert_contains "[I2] ...design's finding names what a test could observe instead" "$FX" \
      "ACCEPTED IF: pipeline.refused.claimed is emitted with no unknown-event warning"
  _run $'RQCL-1: covered\nCLA-10 And: untestable | WHY: it is what a file contains | INSTEAD: the event is emitted once | QUOTE: is registered in config/event-schema.json'
  assert_eq "[I2] an old INSTEAD is read as ACCEPTED IF" "" "$_DESIGN_COV_OUTCOME"
  assert_contains "[I2] ...and reaches design" "$FX" "ACCEPTED IF: the event is emitted once"
  _run $'RQCL-1: covered\nCLA-10 And: untestable | WHY: it is what a file contains | QUOTE: is registered in config/event-schema.json'
  assert_eq "[I3] an untestable line with no ACCEPTED IF cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"
  assert_contains "[I3] ...and the re-ask says so" "$(cat "$_P_FILE")" "CLA-10 And: untestable has no ACCEPTED IF"
  _run $'RQCL-1: covered\nCLA-10 Then: how | WHY: it says how | QUOTE: the run stops'
  assert_eq "[I3] a how line with no ACCEPTED IF cannot be used" "unusable" "$_DESIGN_COV_OUTCOME"

  _run $'RQCL-1: covered\n**CLA-10** And: untestable | **WHY:** it is what a file contains | **ACCEPTED IF:** the event is emitted | QUOTE: is registered in config/event-schema.json'
assert_eq "[I6] a bold ACCEPTED IF is read as ACCEPTED IF" "" "$_DESIGN_COV_OUTCOME"
assert_contains "[I6] ...and reaches design" "$FX" "ACCEPTED IF: the event is emitted"

print_test_section "I4: none is read"
  _run $'RQCL-1: none | WHY: nothing anyone could observe shows an event is reported well | ACCEPTED IF: the requirement names the event a test can see | QUOTE: a refused claim is reported as an event\nCLA-10: ok'
  assert_eq "[I4] a requirement answered none is used" "" "$_DESIGN_COV_OUTCOME"
  assert_eq "[I4] ...and kept as one requirement nothing could observe" "1" "${#_DESIGN_REQ_NONE[@]}"

# ── I5: none stops the run ───────────────────────────────────────────────────
print_test_section "I5: none stops design misconfigured"
FIX="$TEST_TEMP_DIR/fix"; ART="$FIX/state/artifacts"; mkdir -p "$ART"
git -C "$FIX" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$FIX/state/scope-manifest.md"
jq -n '{schema_version: 1, requirements: [{id: "RQCL-1", text: "a refused claim is reported as an event"}]}' > "$FIX/state/requirements.json"
jq -n --arg r "$FIX/state/requirements.json" '{inputs: {a: $r}}' > "$FIX/state/stage-inputs.json"
DRAFT='# Design
Decision: report it.

```steps
- report it | areas: core/pipeline/runner.sh
```

```acceptance
DSCLA-1[code]: a refused claim is reported covers: RQCL-1
  When: a run starts on an issue another runner holds
  Then: the run stops
WIRING: core/pipeline/runner.sh
```'
( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
  route_to_model() {
      if [[ "$2" == *"covers what an ISSUE asked for"* ]]; then
          printf '%s\n' 'RQCL-1: none | WHY: nothing anyone could observe shows an event is reported well | ACCEPTED IF: the requirement names the event a test can see | QUOTE: a refused claim is reported as an event' 'DSCLA-1: ok' 'Steps: ok'
          return 0
      fi
      local _t; _t="$(zb_test_prompt_write_path "$2")"
      [[ -n "$_t" ]] && { mkdir -p "$(dirname "$_t")"; printf '%s\n' "$DRAFT" > "$_t"; }
      printf 'LOOP_COMPLETE\n'; return 0
  }
  _route_loop_close_final_banner() { return 0; }
  export ZBUILD_REPO_ROOT="$FIX" ZBUILD_STAGE_INPUTS="$FIX/state/stage-inputs.json" DRAFT
  _design_stage_run_inner "$FIX/state/scope-manifest.md" "$ART/design.md" "$ART" ) >/dev/null 2>&1
assert_eq "[I5] design stops misconfigured" "misconfigured" "$(jq -r '.outcome // empty' "$ART/design-verdict.json" 2>/dev/null)"
_reason="$(jq -r '.data.reason // .reason // empty' "$ART/design-verdict.json" 2>/dev/null)"
assert_contains "[I5] ...naming the requirement" "$_reason" "RQCL-1"
assert_contains "[I5] ...and why no test can observe it" "$_reason" "nothing anyone could observe shows an event is reported well"
assert_eq "[I5] ...and design.md is not written" "no" "$([[ -e "$ART/design.md" ]] && echo yes || echo no)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
