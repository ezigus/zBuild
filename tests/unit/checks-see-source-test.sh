#!/usr/bin/env bash
# tests/unit/checks-see-source-test.sh — every check that judges work against
# a summary is shown what the summary is of (#2579 R2; ADR-072 §3, amended
# 2026-11-21).
#
# Why: on #1764 run 44863026881 build's step check judged build's answer
# against the step alone; the SPEC the step summarized said "only", the step
# did not, and a fallback that broke the SPEC passed. Each check's prompt is
# built here, and the source it judges against must be in its "What you
# judge against" part.
#
# CS1 design's check: the issue's requirements
# CS2 test-author's assertion check: each SPEC, with its parts
# CS3 issue-acceptance: the issue's words and its requirements
# CS4 a lens: what the change was for — the issue
# CS5 build's step check: the SPECs each step serves, with its parts
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "every check sees the source it judges against (#2579 R2)"
setup_test_env "checks-see-source"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

ISSUE='The holder is read only from comments by the authenticated actor.'
REQ='- RQCLA-1: the holder is read only from the actor'"'"'s comments'
SPEC='DSCLA-23[code]: the holder is only read from comments authored by the authenticated GitHub actor'
SPEC_TEXT='the holder is only read from comments authored by the authenticated GitHub actor'
THEN="the holder read is the actor's"
# _against <prompt> — its "What you judge against" part, or the whole prompt
# for one written without the three parts.
_against() { local p="$1"; [[ "$p" == *"## What you judge against"* ]] && { p="${p#*## What you judge against}"; p="${p%%## What you must not do*}"; }; printf '%s' "$p"; }

print_test_section "CS1: design's check"
_p="$(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _dcov_prompt_judge "$TEST_TEMP_DIR/draft.md" "$SPEC" "$REQ" "" "" "" "$ISSUE"
)"
assert_contains "[CS1] the requirements it judges the SPECs against" "$(_against "$_p")" "$REQ"

print_test_section "CS2: test-author's assertion check"
_p="$(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    _ids=(DSCLA-23); _txts=("$SPEC_TEXT"$'\n'"  Then: $THEN"); _srcs=('>> assert_eq "[DSCLA-23] actor" "a" "$h"')
    _sc_batch_prompt _ids _txts _srcs
)"
assert_contains "[CS2] the SPEC it judges the test against" "$(_against "$_p")" "$SPEC_TEXT"
assert_contains "[CS2] ...with its parts" "$(_against "$_p")" "Then: $THEN"

print_test_section "CS3: issue-acceptance"
_p="$(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
    _ia_prompt "$ISSUE" "$SPEC" "<the change>" pass "$REQ"
)"
assert_contains "[CS3] the issue's words" "$(_against "$_p")" "$ISSUE"
assert_contains "[CS3] ...and its requirements" "$(_against "$_p")" "$REQ"

print_test_section "CS4: a lens"
_p="$(
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" >/dev/null 2>&1
    _rl_build_lens_prompt red-team "<the change>" "ISSUE: $ISSUE"
)"
assert_contains "[CS4] what the change was for" "$(_against "$_p")" "$ISSUE"

print_test_section "CS5: build's step check"
D="$TEST_TEMP_DIR/design.md"; J="$TEST_TEMP_DIR/design-steps.json"
printf '# H\n\n```steps\n- filter by the actor before scanning | areas: lib/h.sh | serves: DSCLA-23\n```\n\n```acceptance\n%s\n  When: another user posts a holder comment\n  Then: %s\nWIRING: none\n```\n' "$SPEC" "$THEN" > "$D"
_p="$(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _design_write_steps "$D" "$J"
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    _build_steps_load "$(cat "$J")"
    _t=""; _build_steps_text_v _t 1
    _build_steps_judge_prompt "### step 1"$'\n'"step: $_t"$'\n'
)"
assert_contains "[CS5] the SPEC the step serves" "$(_against "$_p")" "DSCLA-23: $SPEC_TEXT"
assert_contains "[CS5] ...with its parts" "$(_against "$_p")" "Then: $THEN"
assert_contains "[CS5] ...which the answer must not break" "$(_against "$_p")" "must not break any of these"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
