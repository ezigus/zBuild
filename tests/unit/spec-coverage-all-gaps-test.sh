#!/usr/bin/env bash
# tests/unit/spec-coverage-all-gaps-test.sh — spec-coverage names EVERY gap in
# one answer (#2245).
#
# Why: #1842. Three design rounds, three different "uncovered" requirements —
# all three already missing from the round-1 design. The prompt asked "is there
# anything…?", capped the answer at three lines with a one-sentence reason, and
# never asked for every gap, so each round named the first it found. A 3-round
# loop cannot converge that way.
#
# E1 [change] the prompt asks for every requirement no SPEC fully covers, not
#             only the first found, and says the next round fixes only what is listed
# E2 [change] the answer is not capped at three lines (a full list must fit)
# E3 [guard]  an answer listing three gaps reaches the result and the summary
#             as three gaps
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spec-coverage names every gap at once (#2245)"
setup_test_env "spec-coverage-all-gaps"

# shellcheck source=../../plugins/agent/spec-coverage/plugin.sh
source "$REPO_ROOT/plugins/agent/spec-coverage/plugin.sh" >/dev/null 2>&1
P="$(_scv_prompt "the issue" "the acceptance")"

print_test_section "E1/E2: the prompt"
assert_contains "[E1] it asks for EVERY uncovered requirement" "$P" "EVERY requirement"
assert_contains "[E1] ...not only the first found" "$P" "not only the first"
assert_contains "[E1] ...because the next round fixes only what is listed" "$P" "only what you list"
if grep -qF 'at most three lines' <<< "$P"; then
    assert_fail "[E2] the answer is not capped at three lines" "the prompt still says 'at most three lines'"
else
    assert_pass "[E2] the answer is not capped at three lines"
fi

print_test_section "E3: three gaps travel"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
printf 'Do A. Do B. Do C.\n' > "$S/intake.md"
printf '```acceptance\nSPEC-1[change]: something else\nTESTFILES:\nSPEC-1: tests/x-test.sh\n```\n' > "$S/artifacts/design.md"
(
    export ZBUILD_ARTIFACT_DIR="$S/artifacts" ZBUILD_STATE_DIR="$S"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"
    route_to_model() { printf 'VERDICT: uncovered\nREASON: three requirements have no SPEC\nUNCOVERED: A is required; B is required; C is required\n'; }
    apply_scope_redaction() { cp "$1" "$2"; }
    spec_coverage_run spec-coverage "$S/pipeline-state.json"
) >/dev/null 2>&1
assert_eq "[E3] the result carries three gaps" "3" \
    "$(jq -r '.data.uncovered | length' "$S/artifacts/spec-coverage-result.json" 2>/dev/null)"
assert_eq "[E3] the summary lists three" "3" \
    "$(grep -c 'NOT COVERED' "$S/artifacts/spec-coverage-summary.md" 2>/dev/null || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
