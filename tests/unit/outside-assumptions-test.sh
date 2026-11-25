#!/usr/bin/env bash
# tests/unit/outside-assumptions-test.sh — design, build and the lenses are told
# one rule on what a change assumes about the world outside its code (#2584 R6;
# ADR-038, ADR-040, amended 2026-11-22).
#
# Why: on #1764 the engine claimed issues with a `zbuild:claimed` label that did
# not exist. Design did not name the assumption, build did not check it, and no
# lens could see it.
#
# OA1 [change] the rule names the kinds of outside thing and what handled means
# OA2 [change] design's prompt carries it, and asks design to name each one with
#              how it is handled
# OA3 [change] build's prompt carries it, and asks build to handle each one
# OA4 [change] the lens's prompt carries it (review-lens-asks-test.sh S7 checks
#              the lens's own sentences)
# OA5 [change] (review) design's check judges it: its prompt carries the rule as
#              a judged item of the decisions, and `Decision: unhandled | …` is a
#              finding for design
# OA6 [change] (review) issue-acceptance's prompt carries the rule, beside the
#              read-only lookup that checks one
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "one rule on outside assumptions, for design, build and the lenses (#2584)"
setup_test_env "outside-assumptions"
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }

# shellcheck source=../../scripts/lib/outside-assumptions.sh
source "$REPO_ROOT/scripts/lib/outside-assumptions.sh"
RULE="$(_flat "${ZB_OUTSIDE_ASSUMPTIONS_RULE:-<no rule>}")"; RULE="${RULE% }"

print_test_section "OA1: the rule"
for _k in "a service" "a repository setting" "an environment value" "a data format" "another program's output"; do
    assert_contains "[OA1] it names $_k" "$RULE" "$_k"
done
assert_contains "[OA1] handled: the code creates it" "$RULE" "Handled means the code creates it"
assert_contains "[OA1] ...or checks it and fails clearly" "$RULE" "checks it and fails clearly, with an event or a status line"
assert_contains "[OA1] ...or the design says why it is safe" "$RULE" "the design says why it is safe to assume"

print_test_section "OA2: design"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    route_to_model() { return 0; }
    apply_scope_redaction() { cp "$1" "$2"; }
    atomic_write() { cat - > "$1"; }
    art="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$art"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/state/scope-manifest.md"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/state/events.jsonl" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/state"
    _design_stage_run_inner "$TEST_TEMP_DIR/state/scope-manifest.md" "$art/design.md" "$art" >/dev/null 2>&1 || true
)
D="$(_flat "$(cat "$TEST_TEMP_DIR/state/artifacts/design-prompt.txt" 2>/dev/null)")"
assert_contains "fixture: design's prompt was written" "$D" "acceptance"
assert_contains "[OA2] design's prompt carries the rule" "$D" "$RULE"
assert_contains "[OA2] ...and asks it to name each one" "$D" "Name each outside assumption in the design, with how it is handled"

print_test_section "OA3: build"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
B="$(_flat "$(_build_compose_instructions)")"
assert_contains "[OA3] build's prompt carries the rule" "$B" "$RULE"
assert_contains "[OA3] ...and asks it to handle each one" "$B" "Handle each outside assumption the change makes"

print_test_section "OA4: the lens"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
assert_contains "[OA4] the lens's prompt carries the rule" "$(_flat "$(_rl_build_lens_prompt sre "THE-CHANGE" "")")" "$RULE"

print_test_section "OA5: design's check judges it"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    _P_FILE="$TEST_TEMP_DIR/check-prompt.txt"
    route_to_model() { printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }
    XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR" "$TEST_TEMP_DIR/base"; export _DESIGN_BASE_DIR="$TEST_TEMP_DIR/base"
    D="$TEST_TEMP_DIR/design.md"
    printf '%s\n' '# Design' '' '## Decision' 'The run claims the issue by adding the zbuild:claimed label with gh issue edit.' '' \
        '```acceptance' 'CLA-1[code]: the run claims the issue covers: RQCL-1' '  When: a run starts' '  Then: the issue carries the claimed label' \
        'WIRING: core/pipeline/runner.sh' '```' > "$D"
    _REPLY=$'RQCL-1: covered\nCLA-1: ok\nDecision: unhandled | WHY: the zbuild:claimed label is assumed to exist in the repository | ACCEPTED IF: the design names the label and how a missing one is handled | QUOTE: adding the zbuild:claimed label with gh issue edit'
    : > "$_P_FILE"
    ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "- RQCL-1: the run claims the issue" T2 "" "" "" >/dev/null 2>&1
    printf '%s' "$_DESIGN_COV_OUTCOME" > "$TEST_TEMP_DIR/oa5-outcome"
    _design_coverage_findings > "$TEST_TEMP_DIR/oa5-findings" 2>/dev/null
)
C="$(_flat "$(cat "$TEST_TEMP_DIR/check-prompt.txt" 2>/dev/null)")"
assert_contains "[OA5] the check's prompt carries the rule" "$C" "$RULE"
assert_contains "[OA5] ...as a judged item: one missing is a finding" "$C" \
    "The decisions must name each outside assumption the design makes and how it is handled; one not named, or named without how it is handled, is a finding"
assert_contains_lines "[OA5] ...in the Decision line's form" "$C" \
    $'Decision: unhandled\nwhy: <the outside thing the design assumes, and what it leaves unsaid>\naccepted if: <what the decisions must say about it>\nquote: <the decisions\' words that rely on it>'
assert_eq "[OA5] the answer is used" "" "$(cat "$TEST_TEMP_DIR/oa5-outcome" 2>/dev/null)"
assert_contains "[OA5] ...a finding for design" "$(cat "$TEST_TEMP_DIR/oa5-findings" 2>/dev/null)" \
    "Decision: the design does not handle an outside assumption: the zbuild:claimed label is assumed to exist in the repository — adding the zbuild:claimed label with gh issue edit [FIX IN DESIGN:"

print_test_section "OA6: issue-acceptance"
(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh"
    _ia_prompt "THE-ISSUE" "" "THE-CHANGE" "pass" "- R1: x" > "$TEST_TEMP_DIR/ia-prompt.txt" 2>/dev/null
)
I="$(_flat "$(cat "$TEST_TEMP_DIR/ia-prompt.txt" 2>/dev/null)")"
assert_contains "fixture: issue-acceptance's prompt was written" "$I" "You are checking whether a finished CHANGE"
assert_contains "[OA6] issue-acceptance's prompt carries the rule" "$I" "$RULE"
assert_contains "[OA6] ...one not handled leaves its requirement unmet" "$I" \
    "A requirement whose change rests on an outside assumption it does not handle is unmet"
assert_contains "[OA6] ...beside the read-only lookup" "$I" "check it, read-only, with zbuild-gh-get <endpoint> [jq-filter]"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
