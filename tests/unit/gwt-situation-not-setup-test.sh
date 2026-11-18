#!/usr/bin/env bash
# tests/unit/gwt-situation-not-setup-test.sh — a requirement says what the code
# must do; how a test sets it up, checks it and cleans up after it is the
# test's (ADR-073, amended 2026-11-14, #2543).
#
# Why: on #1700 run 43617030653 design wrote "ZBUILD_PLATFORM=macos is exported
# before scripts/lib/compat.sh is sourced" and "the stat probe module variable
# is inspected". The first cannot hold on Linux (compat.sh resets the variable
# when it loads); test-author's check held its tests to both, and failed four
# of five on its first try. Design was writing the test, not the requirement.
#
# G1 [change] design's prompt: a Given is the situation the code is in, never
#             the steps a test takes; a Then is what can be seen, never how a
#             test looks for it; there is no Cleanup: part
# G2 [change] design's checks refuse a Cleanup: part, saying it is the test's
# G3 [change] design's check no longer asks needs_cleanup, and its `how` covers
#             how a test sets something up or checks it
# G4 [change] a needs_cleanup answer cannot be used
# G5 [change] a part that says how a test sets it up is a finding whose fix says
#             to name the situation, not the test's steps
# G6 [change] test-author's prompt: its test puts back what it changes outside
#             its own sandbox, under its Cleanup section
# G7 [change] test-author's check asks about it, from the test, and what it
#             finds is a finding on the test
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a requirement describes the code; the test is the test's (#2543)"
setup_test_env "gwt-situation-not-setup"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
_l() { grep "^$2|" "$1" | head -1 | cut -d'|' -f2-; }

print_test_section "G1: design's prompt"
_dp="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/plugins/agent/design/lib/run.sh")"
assert_contains "[G1] a Given is the situation the code is in" "$_dp" "Given:\\\` the situation the code is in before the When — never the steps a test takes to get there."
assert_contains "[G1] a Then is what can be seen, never how a test looks" "$_dp" "never how a test looks for it"
if grep -q 'Cleanup:' <<< "$(sed -n '/Under its line, each \[code\]/,/The status says what work/p' "$REPO_ROOT/plugins/agent/design/lib/run.sh")"; then
    assert_fail "[G1] the parts design writes have no Cleanup:" "the prompt still lists Cleanup:"
else assert_pass "[G1] the parts design writes have no Cleanup:"; fi

print_test_section "G2: design's checks"
(
    # shellcheck source=../../scripts/lib/acceptance-block.sh
    source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
    # shellcheck source=../../plugins/agent/design/lib/checks.sh
    source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"
    R="$TEST_TEMP_DIR/repo"; mkdir -p "$R"; git -C "$R" init -q
    D="$TEST_TEMP_DIR/g2.md"
    printf '# Design\n\n```acceptance\nFRSH-1[code]: a new run starts from the first stage\n  When: it is started\n  Then: every stage runs\n  Cleanup: the run folder is gone\nWIRING: none\n```\n' > "$D"
    _design_checks "$D" "$R" "" >/dev/null 2>&1
    v=""; for x in "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}"; do [[ "$x" == GWT_CLEANUP* ]] && v="$x"; done
    echo "G2|$v|$(_dck_plain "$v" 2>/dev/null)"
) > "$TEST_TEMP_DIR/g2.out" 2>/dev/null
assert_contains "[G2] a Cleanup: part is refused" "$(_l "$TEST_TEMP_DIR/g2.out" G2)" "GWT_CLEANUP FRSH-1"
assert_contains "[G2] ...saying putting things back is the test's" "$(_l "$TEST_TEMP_DIR/g2.out" G2)" "putting things back is the test's concern"

print_test_section "G3–G5: design's check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        printf '%s' "$_R1"
    }
    D="$TEST_TEMP_DIR/j.md"
    cat > "$D" <<'MD'
# Design
```acceptance
PRB-1[code]: the in-place edit works when the platform setting is wrong covers: RQST-1
  Given: ZBUILD_PLATFORM=macos is exported before scripts/lib/compat.sh is sourced
  When: the in-place edit runs on a file
  Then: the file is changed
WIRING: none
```
MD
    REQS='- RQST-1: the edit works whatever the platform setting'
    _cov() { printf 0 > "$_N"; _design_coverage "$D" "$REQS" T2 >/dev/null 2>&1; }
    _R1=$'RQST-1: covered\nPRB-1: ok\n'; _cov
    echo "G3|$(tr -s '[:space:]' ' ' < "$_P.1")"
    _R1=$'RQST-1: covered\nPRB-1: needs_cleanup | WHY: it leaves the variable set | QUOTE: ZBUILD_PLATFORM=macos is exported before scripts/lib/compat.sh is sourced\n'; _cov
    echo "G4|$_DESIGN_COV_OUTCOME"
    _R1=$'RQST-1: covered\nPRB-1 Given: how | WHY: it says how a test sets the variable and when it loads the library | INSTEAD: the event the run emits | QUOTE: ZBUILD_PLATFORM=macos is exported before scripts/lib/compat.sh is sourced\n'; _cov
    echo "G5|$(_design_coverage_findings | tr '\n\036' '~~')|$_DESIGN_COV_OUTCOME"
) > "$TEST_TEMP_DIR/j.out" 2>/dev/null
J="$TEST_TEMP_DIR/j.out"
if [[ "$(_l "$J" G3)" == *needs_cleanup* ]]; then assert_fail "[G3] the check no longer asks needs_cleanup" "it still does"
else assert_pass "[G3] the check no longer asks needs_cleanup"; fi
assert_contains "[G3] its how covers how a test sets it up or checks it" "$(_l "$J" G3)" "how — the line says how the code is built, or how a test sets something up or"
assert_eq "[G4] a needs_cleanup answer cannot be used" "unusable" "$(_l "$J" G4)"
assert_contains "[G5] a Given that says how a test sets it up is a finding" "$(_l "$J" G5)" "  Given: ZBUILD_PLATFORM=macos is exported before scripts/lib/compat.sh is sourced [FIX IN DESIGN:"
assert_contains "[G5] ...whose fix names the situation, not the test's steps" "$(_l "$J" G5)" "say the situation, the action, or what can be seen — not how it is built or how a test does it"

print_test_section "G6–G7: test-author"
_tp="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/plugins/agent/test-author/plugin.sh")"
assert_contains "[G6] its test puts back what it changes outside its sandbox" "$_tp" "# Cleanup — putting back anything the test changes outside its own sandbox"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        printf '%s' "$_R1"
    }
    R="$TEST_TEMP_DIR/t-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/t.md"
    cat > "$D" <<'MD'
# Design
```acceptance
LOOP-1[code]: a nested loop starts at round 1
  Given: an outer loop in round 2
  When: the inner loop is entered again
  Then: the inner loop is at round 1
WIRING: none
```
MD
    printf '# Given\nexport ZB_ROUND=2\n# When\nenter_inner\n# Then\nassert_eq "[LOOP-1] inner at 1" "1" "$inner"\n' > "$R/tests/loop-test.sh"
    _j() { printf 0 > "$_N"; rm -rf "$TEST_TEMP_DIR/t-art"; mkdir -p "$TEST_TEMP_DIR/t-art"
           _ta_correspondence "$D" "$R" T2 "$TEST_TEMP_DIR/t-art" >/dev/null 2>&1; }
    _R1=$'LOOP-1: ok\n'; _j
    echo "G7a|$(tr -s '[:space:]' ' ' < "$_P.1")"
    _R1=$'LOOP-1 Then: ok\nLOOP-1 sections: ok\nLOOP-1 cleanup: missing | WHY: it exports ZB_ROUND and never unsets it | QUOTE: tests/loop-test.sh | export ZB_ROUND=2\n'; _j
    echo "G7b|${#_TA_CORR_FINDINGS[@]}|$(tr '\036' '~' <<< "${_TA_CORR_FINDINGS[0]:-}")|$_TA_CORR_OUTCOME"
) > "$TEST_TEMP_DIR/t.out" 2>/dev/null
T="$TEST_TEMP_DIR/t.out"
assert_contains "[G7] the check asks what the test leaves changed outside its sandbox" "$(_l "$T" G7a)" "<identifier> cleanup: missing | WHY: <what the test leaves changed> | QUOTE: <test file> | <the line that changes it>"
assert_contains "[G7] ...and is not asked about a Cleanup part" "$(_l "$T" G7a)" "cleanup: does the test change anything outside its own sandbox"
assert_contains "[G7] what it finds is a finding on the test" "$(_l "$T" G7b)" "1|LOOP-1 cleanup: it exports ZB_ROUND and never unsets it"
assert_contains "[G7] ...that says to put it back" "$(_l "$T" G7b)" "[FIX IN TEST: it exports ZB_ROUND and never unsets it — put it back at the end of the test, under its Cleanup section]"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
