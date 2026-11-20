#!/usr/bin/env bash
# tests/unit/unclear-not-yours-test.sh — test-author and build work from the
# design: what is unclear to them is the design's, sent as a finding, never
# settled by them (#2571 R5, ADR-069 §12).
#
# Why: only a stage that reads the issue directly asks the issue's owner a
# question, and only the raising stage retires its assumption. A stage that
# works from the design and decides the issue's meaning for itself overrides
# the stated assumption in silence.
#
# NY1 [change] the shared rule says what is unclear is the design's, that it
#              goes to design as a finding (not mine — design must …), that the
#              issue's meaning is never theirs to decide, and that a stated
#              assumption is worked to — one thought wrong is a finding to the
#              stage that raised it, never a silent override
# NY2 [change] build's prompt carries the rule
# NY3 [change] test-author's prompt carries the rule
# NY4 [change] neither is given the form: they raise no UNCLEAR line
# NY5 [change] build's rule is a section of its own that takes in none of the
#              bullets of the section before it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "what is unclear to test-author and build is the design's (#2571)"
setup_test_env "unclear-not-yours"
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }

# shellcheck source=../../scripts/lib/unclear.sh
source "$REPO_ROOT/scripts/lib/unclear.sh"
RULE="$(_flat "${ZB_UNCLEAR_NOT_YOURS:-<no rule>}")"; RULE="${RULE% }"

print_test_section "NY1: the rule"
assert_contains "[NY1] what is unclear is the design's" "$RULE" \
    "What is unclear to you about what the issue or the design means is the design's to settle, never yours"
assert_contains "[NY1] ...sent to design as a finding" "$RULE" \
    "ANSWER <the finding as listed>: not mine — design must <what design must settle>: <why>"
assert_contains "[NY1] ...never deciding the issue's meaning" "$RULE" "Never decide the issue's meaning yourself"
assert_contains "[NY1] a stated assumption is worked to" "$RULE" \
    "Work to the assumption a stage stated in an UNCLEAR line under Previous work"
assert_contains "[NY1] ...one thought wrong is a finding to the stage that raised it, never a silent override" "$RULE" \
    "one you think wrong is a finding for the stage that raised it, never a silent override"

print_test_section "NY2: build"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
_B="$(_flat "$(_build_compose_instructions)")"
assert_contains "[NY2] build's prompt carries the rule" "$_B" "${RULE:-<no rule>}"
assert_not_contains "[NY4] ...and is not given the form" "$_B" "ASSUMED: <the reading chosen and acted on>"
_BW="$(_build_compose_instructions | sed -n '/^### How you write the change/,/^### /p')"
assert_contains "[NY5] 'When a test fails' stays under How you write the change" "$_BW" \
    "- When a test fails, find out why it fails before you change anything else."
_BU="$(_build_compose_instructions | sed -n '/^### When something is unclear/,/^### /p')"
assert_not_contains "[NY5] ...and is not under the unclear section" "$_BU" "When a test fails"

print_test_section "NY3: test-author"
# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
TAG="$(acceptance_spec_tag SPEC-1)"
route_to_model_loop() {
    cp "$2" "$TEST_TEMP_DIR/author-prompt"
    _ROUTE_LOOP_ITERATIONS=1
    {
        printf '#!/usr/bin/env bash\n'
        printf 'rc=0\n[[ "$rc" == 1 ]] && echo "  ✓ %s an empty input returns rc 1" || { echo "  ✗ %s an empty input returns rc 1"; exit 1; }\n' "$TAG" "$TAG"
    } > "$R/tests/acc-test.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
route_to_model() { printf 'SPEC-1 Then 1: ok\nSPEC-1 sections: ok\n'; }
d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
mkdir -p "$A" "$R/tests"
( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
    && : > tests/acc-test.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
printf '%s\n' '# Design' '```acceptance' 'SPEC-1[code]: an empty input returns rc 1' 'WIRING: none' \
    'TESTFILES:' 'SPEC-1: tests/acc-test.sh' '```' > "$A/design.md"
export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
_T="$(_flat "$(cat "$TEST_TEMP_DIR/author-prompt" 2>/dev/null)")"
assert_contains "[NY3] test-author's prompt carries the rule" "$_T" "${RULE:-<no rule>}"
assert_not_contains "[NY4] ...and is not given the form" "$_T" "ASSUMED: <the reading chosen and acted on>"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
