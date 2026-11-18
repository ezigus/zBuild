#!/usr/bin/env bash
# tests/unit/lens-check-test.sh — every lens finding names what makes it happen,
# and a separate call tries to knock each lens's findings down before any
# reaches a stage that fixes code (#2552, ADR-038, ADR-072 §3, ADR-051 §5).
#
# Why: on #1700 run 43663836927, 10 of 15 lens findings quoted a real line but
# described a case that cannot happen ("if the load guard is pre-set…"). The
# quote check proves the line, not the claim, and only the lens judged its own.
#
# K1 [change] a finding with no trigger is asked again; still none: unusable
# K2 [change] the routed finding shows its trigger
# K3 [change] a lens with findings makes one check call, given each finding's
#             file, severity, message, trigger and quote; none without findings
# K4 [change] a finding knocked down with a quote found in the code is not
#             routed, is kept under knocked_down, and does not fail the lens
# K5 [change] a finding knocked down with a quote not in the code stands
# K6 [change] the check call runs as quality-assurance: a map element's persona
#             is its main call's only
# K7 [change] the check's answer is kept while the findings and the change are
#             unchanged
# K8 [change] the lens is asked for each problem it can say what makes happen,
#             with the code that shows it
# K9 [change] a knock-down that quotes the finding's own line shows nothing:
#             the finding stands (lens review on #2552)
# K10 [change] a finding knocked down is named, with why, in the lens's summary
#             — a person sees what no stage is sent
# K11 [change] a knock-down quote must be a whole line of the file, and not
#             overlap the finding's own: a fragment like "return 0" shows nothing
# K12 [change] a check call cut short by a signal or its turn limit ends the
#             lens interrupted / out_of_turns, as the lens's own call does
# K13 [change] a trigger that is filler ("unknown", "n/a") is no trigger
# K14 [change] a knock-down whose line the model wrapped is read whole
# K15 [change] a knock-down with no QUOTE is asked again, not read as stands
# K17 [change] (#2556) a finding the code must fix goes to the lens's change
#              output, one a test must fix to its code output; none names a topic
# K18 [change] (review on #2556) a lens finding the issue wrong stops the run
#              whatever type its message is
# K16 [change] a finding written as a plain string is asked again: it has no
#             trigger
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "each lens's findings are checked by a call that tries to knock them down (#2552)"
setup_test_env "lens-check"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
set +e

# A repository whose change adds one line the findings quote.
G="$TEST_TEMP_DIR/repo"; mkdir -p "$G/core"
( cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'keep\n' > core/x.sh && git add -A && git commit -q -m base
  git checkout -q -b feature && printf 'keep\nguard_off() { :; }\n[[ -n "$SAFE" ]] || exit 1\n' > core/x.sh && git commit -qam change ) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$G" ZBUILD_CURRENT_STAGE=review_lenses
export _TPL_STAGE_FAIL_ON_review_lenses="medium high critical"
ART="$TEST_TEMP_DIR/art"; mkdir -p "$ART"
printf 'diff --git a/core/x.sh b/core/x.sh\n+guard_off() { :; }\n' > "$ART/diff.patch"

# The model: a lens call answers $LENS_REPLY (then $LENS_REPLY2 when asked
# again); the check call answers $CHECK_REPLY. Each call is logged with the
# call it was (ZBUILD_ROUTE_CALL) and the persona it would run as.
CALLS="$TEST_TEMP_DIR/calls"
LENS_REPLY="" LENS_REPLY2="" CHECK_REPLY="" CHECK_RC=0
route_to_model() {
    local kind=lens
    [[ "$2" == *"Your job: for each finding below, try to show that it cannot happen"* ]] && kind=check
    printf '%s %s %s\n' "$kind" "${ZBUILD_ROUTE_CALL:-main}" "$(basename "$(resolve_persona review_lenses 2>/dev/null)")" >> "$CALLS"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$kind"
    if [[ "$kind" == check ]]; then printf '%s\n' "$CHECK_REPLY"; return "$CHECK_RC"
    elif [[ -n "$LENS_REPLY2" && "$(grep -c '^lens ' "$CALLS")" -gt 1 ]]; then printf '%s\n' "$LENS_REPLY2"
    else printf '%s\n' "$LENS_REPLY"; fi
}
_finding() {  # <severity> <trigger> — a finding about the added guard_off line
    jq -nc --arg s "$1" --arg t "$2" '{file: "core/x.sh", category: "logic", severity: $s,
        message: "guard_off turns the safety check off", quote: "guard_off() { :; }",
        trigger: $t, introduced: true, fix: "code"}'
}
_lens() {  # run the red-team lens once, fresh
    : > "$CALLS"; rm -f "$ART"/lens-red-team*.json "$ART"/*judged*.json
    ( export ZBUILD_MAP_ELEMENT=red-team ZBUILD_REVIEW_LENS_ID=red-team ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
      cd "$G" && _review_lens_run_inner red-team "" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" ) >/dev/null 2>&1
}
_out() { jq -r "$1" "$ART/lens-red-team.json" 2>/dev/null; }
# The findings here are the code's to fix: they go to the change output (#2556).
_routed() { jq -r '[.data.findings[]?.text] | join("\n")' "$ART/lens-red-team-change-result.json" 2>/dev/null; }
_n() { grep -c "^$1 " "$CALLS" 2>/dev/null || true; }

# ── K1 ───────────────────────────────────────────────────────────────────────
print_test_section "K1: a finding names what makes it happen"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "")]}"; LENS_REPLY2="$LENS_REPLY"; CHECK_REPLY='1: stands'
_lens
assert_eq "[K1] a finding with no trigger is asked again" "2" "$(_n lens)"
assert_contains "[K1] ...saying it names no trigger" "$(cat "$TEST_TEMP_DIR/prompt-lens")" "finding 1 has no trigger"
assert_eq "[K1] ...and still none: the lens is unusable" "unusable" "$(_out .outcome)"

# ── K2 / K3 ──────────────────────────────────────────────────────────────────
print_test_section "K2/K3: the trigger travels; the check is asked"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "a template turns the guard on through outside config")]}"; LENS_REPLY2=""
CHECK_REPLY='1: stands'
_lens
assert_eq "[K3] a lens with findings makes one check call" "1" "$(_n check)"
_cp="$(cat "$TEST_TEMP_DIR/prompt-check" 2>/dev/null)"
assert_contains "[K3] the check is given the finding's message" "$_cp" "guard_off turns the safety check off"
assert_contains "[K3] ...its trigger" "$_cp" "a template turns the guard on through outside config"
assert_contains "[K3] ...its quote" "$_cp" "guard_off() { :; }"
assert_contains "[K3] ...its file and severity" "$_cp" "core/x.sh"
assert_contains "[K2] the routed finding shows its trigger" "$(_routed)" "happens when: a template turns the guard on through outside config"
assert_eq "[K3] the finding stands: the lens fails" "fail" "$(_out .outcome)"
LENS_REPLY='{"score":10,"findings":[]}'
_lens
assert_eq "[K3] a lens with no findings makes no check call" "0" "$(_n check)"

# ── K4 / K5 ──────────────────────────────────────────────────────────────────
print_test_section "K4/K5: knocked down"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "a template turns the guard on")]}"
CHECK_REPLY='1: knocked down | WHY: the line after it exits when SAFE is unset, so nothing outside can turn the check off | QUOTE: core/x.sh | [[ -n "$SAFE" ]] || exit 1'
_lens
assert_eq "[K4] a knocked-down finding is not routed" "" "$(_routed)"
assert_eq "[K4] ...it is kept under knocked_down" "1" "$(_out '.knocked_down | length')"
assert_contains "[K4] ...with why" "$(_out '.knocked_down[0].why')" "exits when SAFE is unset"
assert_eq "[K4] ...and does not fail the lens" "pass" "$(_out .outcome)"
CHECK_REPLY='1: knocked down | WHY: it cannot happen | QUOTE: core/x.sh | a line that is not there'
_lens
assert_contains "[K5] a knock-down whose quote is not in the code: the finding stands" "$(_routed)" "guard_off turns the safety check off"
assert_eq "[K5] ...and fails the lens" "fail" "$(_out .outcome)"

# ── K9 / K10 ─────────────────────────────────────────────────────────────────
print_test_section "K9/K10: knock-downs a person can see, and one that shows nothing"
CHECK_REPLY='1: knocked down | WHY: already guarded | QUOTE: core/x.sh | guard_off() { :; }'
_lens
assert_contains "[K9] a knock-down quoting the finding's own line: the finding stands" "$(_routed)" "guard_off turns the safety check off"
CHECK_REPLY='1: knocked down | WHY: the line after it exits when SAFE is unset | QUOTE: core/x.sh | [[ -n "$SAFE" ]] || exit 1'
_lens
_sum="$(cat "$ART/lens-red-team-summary.md" 2>/dev/null)"
assert_contains "[K10] the summary names the knocked-down finding" "$_sum" "guard_off turns the safety check off"
assert_contains "[K10] ...and why it was knocked down" "$_sum" "exits when SAFE is unset"

# ── K11 ──────────────────────────────────────────────────────────────────────
print_test_section "K11: a knock-down quotes a whole line, not the finding's own"
CHECK_REPLY='1: knocked down | WHY: it exits | QUOTE: core/x.sh | || exit 1'
_lens
assert_contains "[K11] a fragment of a line: the finding stands" "$(_routed)" "guard_off turns the safety check off"
CHECK_REPLY='1: knocked down | WHY: already guarded | QUOTE: core/x.sh | guard_off() {'
_lens
assert_contains "[K11] a quote inside the finding's own: the finding stands" "$(_routed)" "guard_off turns the safety check off"

# ── K12 ──────────────────────────────────────────────────────────────────────
print_test_section "K12: the check cut short"
CHECK_REPLY='' CHECK_RC=130
_lens
assert_eq "[K12] a signal during the check: the lens is interrupted" "interrupted" "$(_out .outcome)"
CHECK_RC=10
_lens
assert_eq "[K12] the check's turn limit: out_of_turns" "out_of_turns" "$(_out .outcome)"
CHECK_RC=0

# ── K13 ──────────────────────────────────────────────────────────────────────
print_test_section "K13: a filler trigger"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "unknown")]}"; LENS_REPLY2="$LENS_REPLY"; CHECK_REPLY='1: stands'
_lens
assert_eq "[K13] a trigger of 'unknown' is asked again" "2" "$(_n lens)"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "a template turns the guard on")]}"; LENS_REPLY2=""

# ── K14 / K15 / K16 ──────────────────────────────────────────────────────────
print_test_section "K14-K16: wrapped, unquoted, and string answers"
CHECK_REPLY='1: knocked down | WHY: the line after it exits when SAFE is
  unset, so nothing outside can turn the check off | QUOTE: core/x.sh | [[ -n "$SAFE" ]] || exit 1'
_lens
assert_eq "[K14] a wrapped knock-down is read whole" "1" "$(_out '.knocked_down | length')"
CHECK_REPLY='1: knocked down | WHY: it cannot happen'
_lens
assert_eq "[K15] a knock-down with no QUOTE is asked again" "2" "$(_n check)"
LENS_REPLY='{"score":4,"findings":["guard_off turns the safety check off"]}'; LENS_REPLY2="$LENS_REPLY"; CHECK_REPLY='1: stands'
_lens
assert_eq "[K16] a finding written as a string is asked again" "2" "$(_n lens)"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "a template turns the guard on")]}"; LENS_REPLY2=""

# ── K6 ───────────────────────────────────────────────────────────────────────
print_test_section "K6: the check runs as quality-assurance"
CHECK_REPLY='1: stands'
( export _TPL_SOURCE_FILE="$TEST_TEMP_DIR/tpl.yaml"
  cat > "$_TPL_SOURCE_FILE" <<'YAML'
id: k6
flow:
  - review_lenses
review_lenses:
  type: map
  over: lenses
  elements:
    - id: red-team
      persona: red-team
  roles: [review_lens]
YAML
  : > "$CALLS"; rm -f "$ART"/lens-red-team*.json "$ART"/*judged*.json
  export ZBUILD_MAP_ELEMENT=red-team ZBUILD_REVIEW_LENS_ID=red-team ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
  cd "$G" && _review_lens_run_inner red-team "" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" ) >/dev/null 2>&1
assert_eq "[K6] the lens's own call runs as its element's persona" "lens main red-team" "$(grep '^lens ' "$CALLS" | head -1)"
assert_eq "[K6] the check call runs as quality-assurance" "check check quality-assurance" "$(grep '^check ' "$CALLS" | head -1)"

# ── K7 ───────────────────────────────────────────────────────────────────────
print_test_section "K7: a kept check answer"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "a template turns the guard on")]}"; CHECK_REPLY='1: stands'
_lens
: > "$CALLS"
( export ZBUILD_MAP_ELEMENT=red-team ZBUILD_REVIEW_LENS_ID=red-team ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
  rm -f "$ART/lens-red-team-judged.json"
  cd "$G" && _review_lens_run_inner red-team "" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" ) >/dev/null 2>&1
assert_eq "[K7] the same findings on the same change: the kept check answer is used" "0" "$(_n check)"

# ── K8 ───────────────────────────────────────────────────────────────────────
print_test_section "K8: the lens's wording"
assert_contains "[K8] the lens is asked for each problem it can say what makes happen" \
    "$(_rl_build_lens_prompt red-team "EVIDENCE" "CONTEXT" 2>/dev/null | tr -s '[:space:]' ' ')" \
    "each problem in the change you can say what makes happen, and quote the code that shows it"

# ── K17 ──────────────────────────────────────────────────────────────────────
print_test_section "K17: one output per topic (#2556)"
_tfind="$(_finding medium "an operator runs it" | jq -c '.fix = "test" | .message = "the test never checks the guard"')"
LENS_REPLY="{\"score\":4,\"findings\":[$(_finding medium "an operator runs it"),$_tfind]}"; LENS_REPLY2=""; CHECK_REPLY=$'1: stands\n2: stands'
_lens
assert_contains "[K17] a finding the code must fix goes to the change output" \
    "$(jq -r '[.data.findings[]?.text] | join(" ")' "$ART/lens-red-team-change-result.json" 2>/dev/null)" "guard_off turns the safety check off"
assert_contains "[K17] one a test must fix goes to the code output" \
    "$(jq -r '[.data.findings[]?.text] | join(" ")' "$ART/lens-red-team-code-result.json" 2>/dev/null)" "the test never checks the guard"
assert_eq "[K17] ...and only it" "1" "$(jq -r '.data.findings | length' "$ART/lens-red-team-code-result.json" 2>/dev/null)"
assert_eq "[K17] no routed finding names a topic of its own" "0" \
    "$(cat "$ART"/lens-red-team-*-result.json 2>/dev/null | grep -c '"topic"' || true)"

# ── K18 ──────────────────────────────────────────────────────────────────────
print_test_section "K18: a lens whose routing fails is not a pass (review on #2556)"
_ifind="$(_finding high "always" | jq -c '.fix = "issue" | .message = 42')"
LENS_REPLY="{\"score\":4,\"findings\":[$_ifind]}"; LENS_REPLY2=""; CHECK_REPLY='1: stands'
_lens
assert_eq "[K18] an issue finding whose message is a number still stops the run" "misconfigured" "$(_out .outcome)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
