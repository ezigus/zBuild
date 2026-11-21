#!/usr/bin/env bash
# plugins/agent/build/tests/build-step-specs-test.sh — build's step check is
# shown the SPECs each step serves, and a changed step is judged as a change
# (#2579 R2 R3; ADR-072 §3 §4, amended 2026-11-21).
#
# Why: on #1764 run 44863026881 step 1 said "filter by the authenticated actor
# before scanning". DSCLA-23 said the code "only reads from comments authored
# by the authenticated actor". Build added a fallback that read any commenter;
# the step's check, shown only the step, passed it. Later step 1 gained the
# actor-filter clause; build answered "not needed — done in prior iterations"
# and the check, shown only the new text, accepted it.
#
# SS1 [R2] the step check is shown the text of each SPEC the step serves, under
#          what it judges against, and told the answer must not break any
# SS2 [R2] a SPEC a step serves changes: the step's kept verdict is not used —
#          it is judged again
# SS3 [R3] a step whose words changed since the check last answered it: the
#          check is shown the step as it was and as it is now, and told the
#          new part must be shown done — "done before" cannot cover it
# SS4 [R3] ...and build's own prompt marks the step as changed, with its old
#          and new words
# SS5 [R3] a step kept before its words were saved (an older record) is judged
#          afresh, with no "was"
# SS7 [review] a check that ends early (its call interrupted) leaves no item
#          text behind for another check's kept record
# SS8 [review] a step that only moved (design inserts a new step 1; the old
#          step 1 is now step 2) is not shown as changed, and neither is the
#          new step 1
# SS9 [review] each SPEC's text in a step's item, and each side of was / now,
#          is capped
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "build's step check sees the SPECs; a changed step is a change (#2579)"
setup_test_env "plugin-build-step-specs"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_RUN_ID="build-step-specs-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE

# ── The design, written by design's own writer ───────────────────────────────
STEP1='filter the holder comments by the authenticated actor before scanning'
STEP1B='filter the holder comments by the authenticated actor before scanning, and read no other commenter'
SPEC23='the holder is only read from comments authored by the authenticated GitHub actor'
SPEC23B='the holder is only read from comments authored by the authenticated GitHub actor, never from another commenter'
DESIGN_MD="$TEST_TEMP_DIR/design.md"
STEPS="$TEST_TEMP_DIR/design-steps.json"
_design() {   # <step 1 words> <DSCLA-23 words>
    printf '# Holder\n\n## Decision\nRead the actor only.\n\n```steps\n- %s | areas: lib/holder.sh | serves: DSCLA-23\n```\n\n```acceptance\nDSCLA-23[code]: %s\n  When: another user posts a holder comment\n  Then: the holder read is the actor'"'"'s\nWIRING: none\n```\n' \
        "$1" "$2" > "$DESIGN_MD"
    (
        # shellcheck source=../../../../plugins/agent/design/plugin.sh
        source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
        _design_write_steps "$DESIGN_MD" "$STEPS"
    )
}
_design "$STEP1" "$SPEC23"
assert_eq "[setup] design wrote the step and the SPEC it serves" "DSCLA-23" "$(jq -r '.steps[0].serves[0]' "$STEPS" 2>/dev/null)"

# ── The repository: the base, and a branch that added the filter ─────────────
R="$TEST_TEMP_DIR/repo"; LINE='body="$(gh_comments_by "$actor")"'
mkdir -p "$R/lib"
(
    cd "$R" && git init -q -b main && git config user.email t@zbuild && git config user.name t
    printf '%s\n' 'read_holder() { :; }' > lib/holder.sh
    git add -A && git commit -q -m base
    git checkout -q -b zbuild/issue-1764
    printf '%s\n' 'read_holder() {' "    $LINE" '}' > lib/holder.sh
    git add -A && git commit -q -m "filter"
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$R"

# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; }
_route_loop_close_final_banner() { return 0; }
MOCK_LOOP_RESPONSE=""
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=1; _ROUTE_LOOP_OUTPUT_TOKENS=1
    _ROUTE_LOOP_LAST_RESPONSE="$MOCK_LOOP_RESPONSE"
    return 0
}
CALLS="$TEST_TEMP_DIR/calls"; JPROMPT="$TEST_TEMP_DIR/judge-prompt"; JUDGE_REPLY=""
route_to_model() {
    printf '%s\n' "${ZBUILD_ROUTE_CALL:-main}" >> "$CALLS"
    printf '%s' "$2" > "$JPROMPT"
    printf '%s\n' "$JUDGE_REPLY"
}
AD="$TEST_TEMP_DIR/art"; mkdir -p "$AD"
_run() {   # <build reply> — one build try in the same folder, with the latest steps
    cp "$STEPS" "$AD/design-steps.json"
    MOCK_LOOP_RESPONSE="$1"; : > "$CALLS"; rm -f "$JPROMPT"
    _build_stage_run_inner "" "$AD/design-steps.json" "$AD/diff.patch" "$AD/build-summary.json" "$AD" >"$AD/log" 2>&1 || true
}
_ncalls() { local n=0 l; while IFS= read -r l; do [[ -n "$l" ]] && n=$((n + 1)); done < "$CALLS"; printf '%s' "$n"; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
DONE1="step 1: done — QUOTE: lib/holder.sh | $LINE"

# ── SS1 ──────────────────────────────────────────────────────────────────────
print_test_section "SS1: the step check is shown the SPECs the step serves"
JUDGE_REPLY='1: does'
_run "$DONE1"$'\nLOOP_COMPLETE'
_jp="$(cat "$JPROMPT" 2>/dev/null)"
_against="${_jp#*## What you judge against}"; _against="${_against%%## What you must not do*}"
assert_contains "[SS1] the SPEC's text is under what the check judges against" "$_against" "DSCLA-23: $SPEC23"
assert_contains "[SS1] ...with its parts" "$_against" "Then: the holder read is the actor's"
assert_contains "[SS1] ...and the answer must not break any of them" "$_jp" "must not break any of these"

# ── SS2 ──────────────────────────────────────────────────────────────────────
print_test_section "SS2: a changed SPEC has the step judged again"
_run "$DONE1"$'\nLOOP_COMPLETE'
assert_eq "[SS2] setup: nothing changed, the kept verdict is used" "0" "$(_ncalls)"
_design "$STEP1" "$SPEC23B"
_run "$DONE1"$'\nLOOP_COMPLETE'
assert_eq "[SS2] the SPEC changed: the step is judged again" "1" "$(_ncalls)"
assert_contains "[SS2] ...shown the SPEC as it is now" "$(cat "$JPROMPT" 2>/dev/null)" "$SPEC23B"

# ── SS3 / SS4 ────────────────────────────────────────────────────────────────
print_test_section "SS3: a step whose words changed is judged as a change"
_design "$STEP1B" "$SPEC23B"
JUDGE_REPLY='1: does not | WHY: the new clause is not shown done | ACCEPTED IF: no other commenter is read'
_run $'step 1: not needed — done in prior iterations\nLOOP_COMPLETE'
_jp="$(cat "$JPROMPT" 2>/dev/null)"
assert_contains "[SS3] the check is shown the step as it was" "$_jp" "was: $STEP1"
assert_contains "[SS3] ...and as it is now" "$_jp" "now: $STEP1B"
assert_contains "[SS3] ...and told \"done before\" cannot cover the new part" "$_jp" "\"done before\" cannot cover it"
_bp="$(cat "$AD/build-prompt.txt" 2>/dev/null)"
assert_contains "[SS4] build's prompt marks step 1 as changed" "$_bp" "step 1 changed since you last answered it"
assert_contains "[SS4] ...with its old words" "$_bp" "was: $STEP1"

# ── SS5 ──────────────────────────────────────────────────────────────────────
print_test_section "SS5: an older record, with no words saved"
# The record as the writer wrote it before #2579: its saved words taken out.
jq -c 'with_entries(.value |= del(.text))' "$AD/build-steps-judged.json" > "$AD/k.json" && mv "$AD/k.json" "$AD/build-steps-judged.json"
_design "$STEP1" "$SPEC23B"
JUDGE_REPLY='1: does'
_run "$DONE1"$'\nLOOP_COMPLETE'
assert_eq "[SS5] the step is judged afresh" "1" "$(_ncalls)"
_lacks "[SS5] ...with no \"was\"" "$(cat "$JPROMPT" 2>/dev/null)" "was: "

# ── SS7 ──────────────────────────────────────────────────────────────────────
print_test_section "SS7: a check that ends early leaves no item text behind"
rm -f "$AD/build-steps-judged.json"
route_to_model() { printf '%s\n' "${ZBUILD_ROUTE_CALL:-main}" >> "$CALLS"; return 130; }
_run "$DONE1"$'\nLOOP_COMPLETE'
assert_eq "[SS7] setup: the step check was called and interrupted" "check" "$(cat "$CALLS" 2>/dev/null)"
declare -A _op=([step-1]="1: does") _of=([step-1]=fp1) _od=()
judge_kept_put_all "$TEST_TEMP_DIR/other-judged.json" _op _of _od
assert_eq "[SS7] another check's record holds no text it was not given" "null" "$(jq -c '.["step-1"].text' "$TEST_TEMP_DIR/other-judged.json" 2>/dev/null)"
route_to_model() {
    printf '%s\n' "${ZBUILD_ROUTE_CALL:-main}" >> "$CALLS"
    printf '%s' "$2" > "$JPROMPT"
    printf '%s\n' "$JUDGE_REPLY"
}

# ── SS8 ──────────────────────────────────────────────────────────────────────
print_test_section "SS8: a moved step is not a changed step"
_design "$STEP1" "$SPEC23"
JUDGE_REPLY='1: does'
_run "$DONE1"$'\nLOOP_COMPLETE'
assert_eq "[SS8] setup: step 1 judged and kept" "1" "$(_ncalls)"
# Design inserts a new step 1; the old step 1 is now step 2, word for word.
sed -i.bak "s#^- $STEP1 #- log each holder read | areas: lib/holder.sh | serves: DSCLA-23\\
- $STEP1 #" "$DESIGN_MD"; rm -f "$DESIGN_MD.bak"
( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1; _design_write_steps "$DESIGN_MD" "$STEPS" )
assert_eq "[SS8] setup: two steps, the old one second" "log each holder read|$STEP1" "$(jq -r '[.steps[].description] | join("|")' "$STEPS" 2>/dev/null)"
JUDGE_REPLY=$'1: does\n2: does'
_run "$DONE1"$'\nstep 2: done — QUOTE: lib/holder.sh | '"$LINE"$'\nLOOP_COMPLETE'
_lacks "[SS8] build's prompt marks no step as changed" "$(cat "$AD/build-prompt.txt" 2>/dev/null)" "changed since you last answered it"
_lacks "[SS8] the step check is shown no step as changed" "$(cat "$JPROMPT" 2>/dev/null)" "CHANGED SINCE IT WAS LAST ANSWERED"

# ── SS9 ──────────────────────────────────────────────────────────────────────
print_test_section "SS9: caps"
_long="$(printf 'a%.0s' {1..1500})"
_design "$STEP1" "$SPEC23 $_long"
_run "$DONE1"$'\nLOOP_COMPLETE'
_jp="$(cat "$JPROMPT" 2>/dev/null)"
assert_eq "[SS9] a SPEC's text in the step's item is capped" "0" "$([[ "$_jp" == *"$_long"* ]] && echo 1 || echo 0)"
assert_contains "[SS9] ...and says so" "$_jp" "…"
_e=""; judge_changed_entry_v _e "x" "$_long" "$_long"
assert_eq "[SS9] each side of was / now is capped" "0" "$([[ "$_e" == *"$_long"* ]] && echo 1 || echo 0)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
