#!/usr/bin/env bash
# tests/unit/ids-one-rule-test.sh — a stage that numbers ids tells its model
# each code's highest number from the same function its check uses (#2550,
# ADR-069 §1, ADR-070 §1).
#
# Why: on #1764 run 43735596812 design's prompt said a new SPEC's number is one
# past the highest "in any test file", and a dropped SPEC gets REMOVED "so its
# id is never used again". The check counts only the last design that passed.
# Try 2 wrote REMOVED lines for try 1's ids and numbered DSNCI-3; the check said
# "use DSNCI-1", and a try was lost on the prompt's own rule.
#
# N1 [change] the line names each code's highest number, removed ones counted,
#             and says a new code starts at 1; with none used, every code does
# N2 [change] design's prompt gives that line, from the last design that passed
# N3 [change] a design numbered as its prompt says passes design's id check —
#             with an earlier design, and with none but a failed try's ids
# N4 [change] design's prompt states no rule of its own: no "in any test file",
#             no "never used again" for an id only a failed try wrote
# N5 [change] intake's prompts give the same line, from its last list
# N6 [change] a test tag is the id alone (#2520), so an id another piece of
#             work tagged in the repository's tests is taken: design's prompt
#             and its check both count those tags, so a new id is past them
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "one numbering rule: the prompt's numbers come from the check's function (#2550)"
setup_test_env "ids-one-rule"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# shellcheck source=../../scripts/lib/item-ids.sh
source "$REPO_ROOT/scripts/lib/item-ids.sh"
set +e
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it holds: $3"; else assert_pass "$1"; fi; }

# ── N1 ───────────────────────────────────────────────────────────────────────
print_test_section "N1: the line"
_l=""; zb_ids_highest_line_v _l "DSCLM-1 DSCLM-2 DSREL-1" "DSREL-3" DS SPEC 2>/dev/null
assert_contains "[N1] each code's highest, removed ones counted" "$_l" "DSCLM 2, DSREL 3"
assert_contains "[N1] ...a new one takes the next" "$_l" "takes the next number"
assert_contains "[N1] ...a new code starts at 1" "$_l" "a new code starts at 1"
_l=""; zb_ids_highest_line_v _l "" "" DS SPEC 2>/dev/null
assert_contains "[N1] none used: every code starts at 1" "$_l" "No SPEC id is taken yet: every code starts at 1"

# ── N2 / N3 / N4: design ─────────────────────────────────────────────────────
FIX="$TEST_TEMP_DIR/fix"; ART="$FIX/state/artifacts"; mkdir -p "$ART"
git -C "$FIX" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$FIX/state/scope-manifest.md"
_design_prompt() {  # the design prompt, with design.md as the last design that passed (or none)
    ( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
      route_to_model() { return 1; }
      _route_loop_close_final_banner() { return 0; }
      export ZBUILD_REPO_ROOT="$FIX"
      _design_stage_run_inner "$FIX/state/scope-manifest.md" "$ART/design.md" "$ART" ) >/dev/null 2>&1
    cat "$ART/design-prompt.txt" 2>/dev/null
}
_ids_ok() {  # <draft> — design's own id check on <draft>, design.md the last that passed
    ( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
      _design_checks "$1" "$FIX" "" "$ART/design.md" >/dev/null 2>&1
      printf '%s\n' "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}" ) | /usr/bin/grep '^ID_' || true
}
print_test_section "N2/N3: design, with an earlier design"
printf '%s\n' '# Design' '```acceptance' 'DSCLM-1[doc]: one' 'DSCLM-2[doc]: two' 'REMOVED: DSREL-3 — gone' 'WIRING: none' '```' > "$ART/design.md"
_p="$(_design_prompt)"
assert_contains "[N2] design's prompt gives each code's highest from the last design that passed" "$_p" "DSCLM 2, DSREL 3"
printf '%s\n' '# Design' '```acceptance' 'DSCLM-1[doc]: one' 'DSCLM-2[doc]: two' 'DSCLM-3[doc]: three' 'DSREL-4[doc]: four' 'REMOVED: DSREL-3 — gone' 'WIRING: none' '```' > "$TEST_TEMP_DIR/draft-a.md"
assert_eq "[N3] a design numbered as the prompt says passes the id check" "" "$(_ids_ok "$TEST_TEMP_DIR/draft-a.md")"
print_test_section "N3: design, with none passed and a failed try's ids"
rm -f "$ART/design.md"
mkdir -p "$ART/attempts/design/iter-1-attempt-1"
printf '%s\n' '# Design' '```acceptance' 'DSNCI-1[doc]: built it' 'DSNCI-2[doc]: built more' 'WIRING: none' '```' > "$ART/attempts/design/iter-1-attempt-1/design-draft.md"
_p="$(_design_prompt)"
assert_contains "[N2] with none passed, the prompt says every code starts at 1" "$_p" "No SPEC id is taken yet: every code starts at 1"
printf '%s\n' '# Design' '```acceptance' 'DSNCI-1[doc]: the CI status is never read' 'WIRING: none' '```' > "$TEST_TEMP_DIR/draft-b.md"
assert_eq "[N3] ...and a design numbered so passes, though a failed try used DSNCI-1" "" "$(_ids_ok "$TEST_TEMP_DIR/draft-b.md")"
print_test_section "N4: design states no rule of its own"
_lacks "[N4] no 'in any test file'" "$_p" "in any test file"
_lacks "[N4] no 'never used again' for every dropped SPEC" "$_p" "so its id is never used again"
assert_contains "[N4] REMOVED is for a SPEC of the last design that passed" "$_p" "REMOVED: only for a SPEC in the last design that passed"

# ── N6: ids tagged in the repository's tests ───────────────────────────────
print_test_section "N6: an id tagged in the tests is taken"
mkdir -p "$FIX/tests"
printf 'assert_eq "[DSCLM-5] other work" 1 1\n' > "$FIX/tests/other-test.sh"
git -C "$FIX" add tests/other-test.sh >/dev/null 2>&1
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m other >/dev/null 2>&1
printf '%s\n' '# Design' '```acceptance' 'DSCLM-1[doc]: one' 'DSCLM-2[doc]: two' 'WIRING: none' '```' > "$ART/design.md"
_p="$(_design_prompt)"
assert_contains "[N6] design's prompt counts the id tagged in the tests" "$_p" "DSCLM 5"
printf '%s\n' '# Design' '```acceptance' 'DSCLM-1[doc]: one' 'DSCLM-2[doc]: two' 'DSCLM-3[doc]: three' 'WIRING: none' '```' > "$TEST_TEMP_DIR/draft-c.md"
assert_contains "[N6] design's check refuses a new id at or below it" "$(_ids_ok "$TEST_TEMP_DIR/draft-c.md")" "ID_NOT_AFTER_LAST DSCLM-3 DSCLM-6"
printf '%s\n' '# Design' '```acceptance' 'DSCLM-1[doc]: one' 'DSCLM-2[doc]: two' 'DSCLM-6[doc]: six' 'WIRING: none' '```' > "$TEST_TEMP_DIR/draft-d.md"
assert_eq "[N6] ...and passes the one the prompt says" "" "$(_ids_ok "$TEST_TEMP_DIR/draft-d.md")"
rm -f "$ART/design.md"

# ── N5: intake ───────────────────────────────────────────────────────────────
print_test_section "N5: intake"
( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
  # shellcheck source=../../plugins/agent/intake/plugin.sh
  source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  export _INTAKE_PREV_REQ_JSON='{"schema_version":1,"source":"model","requirements":[{"id":"RQCLM-1","text":"a"},{"id":"RQCLM-2","text":"b"}],"removed":[{"id":"RQREL-4","text":"c","reason":"d"}],"issue_ids":[]}'
  : > "$TEST_TEMP_DIR/n5c"
  route_to_model() {
      local n; n=$(( $(grep -c . "$TEST_TEMP_DIR/n5c") + 1 )); printf 'x\n' >> "$TEST_TEMP_DIR/n5c"
      printf '%s' "$2" > "$TEST_TEMP_DIR/n5p-$n"
      if [[ "$2" == *"Your job: check a list"* ]]; then printf 'MISSING: none\n'; else printf 'REQUIREMENT: RQCLM-1 a\nREQUIREMENT: RQCLM-2 b\n'; fi
  }
  local _j; _intake_requirements_json_v _j '{"title":"t","body":"a\nb"}' ) >/dev/null 2>&1
assert_contains "[N5] intake's write prompt gives each code's highest from its last list" "$(cat "$TEST_TEMP_DIR/n5p-1" 2>/dev/null)" "RQCLM 2, RQREL 4"
assert_contains "[N5] intake's check prompt gives it too" "$(cat "$TEST_TEMP_DIR/n5p-2" 2>/dev/null)" "RQCLM 2, RQREL 4"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
