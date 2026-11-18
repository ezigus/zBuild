#!/usr/bin/env bash
# tests/unit/finding-owner-topics-test.sh — the test stage sends a failing test
# to whoever owns it (#2454, ADR-071 §1 §2; #2556: through one output per topic,
# no longer a topic a finding names of its own).
#
# Why: on #1805 (run 41452299475) test-author was handed 27 problems — 12
# failing test files, 7 of them tests it did not write, and 9 shape-check
# findings about other tests — and spent its whole call sorting them. #2452
# let a finding carry its own topic, but only two stages used it, and nothing
# made a stage decide.
#
#   O1 [change]: acceptance_list_testfiles prints each test file once (#2508:
#                the files holding a SPEC's tag, sorted)
#   (O2–O4 went with finding_topics: — #2556, tests/unit/finding-topics-test.sh F9)
#   O5 [change]: a failing file that is one of the design's test files (#2508:
#                test-folder files holding its tags) goes to test's code output;
#                any other to its change output (#2556)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "the test stage sends a failing test to whoever owns it (#2454, #2556)"
setup_test_env "finding-owner-topics"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

DESIGN="$TEST_TEMP_DIR/design.md"
printf '%s\n' '# Design' '```acceptance' 'SPEC-1[code]: a' 'SPEC-2[code]: b' 'SPEC-3[code]: c' \
    'WIRING: none' '```' > "$DESIGN"
# #2508: the design's test files are those in the test folders holding its tags.
TREPO="$TEST_TEMP_DIR/repo"; mkdir -p "$TREPO/tests"; git -C "$TREPO" init -q
printf 'assert "%s" ; assert "%s" ; assert "%s"\n' "$(acceptance_spec_tag SPEC-1)" "$(acceptance_spec_tag SPEC-2)" \
    "$(acceptance_spec_tag SPEC-3)" > "$TREPO/tests/a-test.sh"
printf 'assert "%s"\n' "$(acceptance_spec_tag SPEC-2)" > "$TREPO/tests/b-test.sh"
printf 'assert "unrelated"\n' > "$TREPO/tests/other-test.sh"
export ZBUILD_REPO_ROOT="$TREPO"

# ── O1 ───────────────────────────────────────────────────────────────────────
print_test_section "O1: each test file once"
assert_eq "[O1] each test file is listed once, sorted" \
    $'tests/a-test.sh\ntests/b-test.sh' "$(acceptance_list_testfiles "$DESIGN")"

# ── O5 ───────────────────────────────────────────────────────────────────────
print_test_section "O5: the test stage labels by whose test it is"
# shellcheck source=../../plugins/tool/test/lib/findings.sh
source "$REPO_ROOT/plugins/tool/test/lib/findings.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
O5D="$TEST_TEMP_DIR/o5"; mkdir -p "$O5D"
printf 'tests/a-test.sh\tA-FAILS\ntests/other-test.sh\tOTHER-FAILS\n' \
    | _test_findings_by_owner "$DESIGN" | stage_findings_route "$O5D" test code-findings >/dev/null
assert_eq "[O5] the design's own test file goes to test's code output" "A-FAILS" \
    "$(jq -r '[.data.findings[].text] | join(" ")' "$O5D/test-code-result.json" 2>/dev/null)"
assert_eq "[O5] any other test file goes to its change output" "OTHER-FAILS" \
    "$(jq -r '[.data.findings[].text] | join(" ")' "$O5D/test-change-result.json" 2>/dev/null)"
printf 'tests/other-test.sh\tNO-DESIGN\n' | _test_findings_by_owner "" | stage_findings_route "$O5D" test code-findings >/dev/null
assert_eq "[O5] with no design, every file goes to the change output" "NO-DESIGN" \
    "$(jq -r '[.data.findings[].text] | join(" ")' "$O5D/test-change-result.json" 2>/dev/null)"
assert_file_not_exists "[O5] ...and no code output is left" "$O5D/test-code-result.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
