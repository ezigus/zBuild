#!/usr/bin/env bash
# tests/unit/test-author-supersedes-test.sh — an existing check that this change
# makes wrong has an owner (#2243).
#
# Why: #1842. Its design said an old check (the [SPEC-3] forbidden-word grep in
# review-aggregator-test.sh) becomes wrong under the change. Those files also
# held this issue's SPEC tests, so build could not edit them (read-only, and
# restored), and test-author never saw the design's steps — its prompt held the
# SPEC sentences and paths only, and said another tag must "never change". No
# stage could make the edit, so build built the word `verdict` from two printf
# calls to slip past the old grep.
#
# The fix keeps stages apart: design states, as a FACT ABOUT THE CHANGE, which
# existing checks it makes wrong (a ```supersedes block in design.md); updating
# them to the new behaviour is part of test-author's job, as writing the new
# ones is. Only the listed checks become editable.
#
# S1 [change] acceptance_list_supersedes reads the block: path, tag, why;
#             absolute and ../ paths are refused; no block → nothing
# S2 [change] test-author's prompt lists those checks and says to update them
# S3 [change] ...and may write the files that hold them (they reach the loop's
#             context paths)
# S4 [guard]  with no block, the prompt carries no such section and the
#             "another tag: never change" rule stands
# S5 [change] design is told it can declare the block
# S6 [change] every supersedes block is read, not only the first (review #2247)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"

print_test_header "an existing check this change makes wrong has an owner (#2243)"
setup_test_env "test-author-supersedes"
unset ZBUILD_ISSUE 2>/dev/null || true

D="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$D" "$TEST_TEMP_DIR/repo/tests"
_design() {
    cat > "$D/design.md" <<'EOF'
# Design

```acceptance
SPEC-1[change]: the report carries a v2 verdict
TESTFILES:
SPEC-1: tests/new-test.sh
```
EOF
    [[ "${1:-}" == with ]] && cat >> "$D/design.md" <<'EOF'

```supersedes
tests/old-test.sh [SPEC-3]: `verdict` is now the v2 result's status key, not a merge decision
/etc/passwd [SPEC-9]: absolute — refused
../outside-test.sh [SPEC-8]: traversal — refused
```
EOF
    return 0
}

print_test_section "S1: the block"
_design with
_sup="$(acceptance_list_supersedes "$D/design.md" 2>/dev/null)"
assert_eq "[S1] one listed check, as path<TAB>tag<TAB>why" \
    $'tests/old-test.sh\t[SPEC-3]\t`verdict` is now the v2 result\'s status key, not a merge decision' "$_sup"
_design
assert_eq "[S1] no block → nothing" "" "$(acceptance_list_supersedes "$D/design.md" 2>/dev/null)"

# _author — run test-author with a stubbed loop that records its prompt and args.
_author() {
    (
        export ZBUILD_ARTIFACT_DIR="$D" ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
        export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"
        # shellcheck source=../../plugins/agent/test-author/plugin.sh
        source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
        route_to_model_loop() {
            cp "$2" "$TEST_TEMP_DIR/prompt.txt"; printf '%s\n' "$@" > "$TEST_TEMP_DIR/args.txt"
            _ROUTE_LOOP_TERMINATED_REASON=done_sentinel; return 0
        }
        _ta_commit_testfiles() { return 0; }
        cd "$TEST_TEMP_DIR/repo" && test_author_run test-author "$TEST_TEMP_DIR/state/pipeline-state.json"
    ) >/dev/null 2>&1
}

_design with
printf '\n```supersedes\ntests/other-test.sh [SPEC-4]: a second block\n```\n' >> "$D/design.md"
assert_contains "[S6] a second supersedes block is read too" "$(acceptance_list_supersedes "$D/design.md" 2>/dev/null)" "tests/other-test.sh"

print_test_section "S2/S3: test-author with a supersedes block"
_design with; _author
_p="$(cat "$TEST_TEMP_DIR/prompt.txt" 2>/dev/null)"
assert_contains "[S2] the prompt lists the check this change makes wrong" "$_p" "tests/old-test.sh [SPEC-3]"
assert_contains "[S2] ...with why" "$_p" "is now the v2 result's status key"
assert_contains "[S2] ...and says to update it to the new behaviour" "$_p" "EXISTING CHECKS THIS CHANGE MAKES WRONG"
assert_contains "[S3] the file holding it reaches the loop's context paths" "$(cat "$TEST_TEMP_DIR/args.txt" 2>/dev/null)" "tests/old-test.sh"
if grep -qF '/etc/passwd' <<< "$_p"; then
    assert_fail "[S1] a refused path does not reach the prompt" "$_p"
else
    assert_pass "[S1] a refused path does not reach the prompt"
fi

print_test_section "S4: no block"
_design; _author
_p4="$(cat "$TEST_TEMP_DIR/prompt.txt" 2>/dev/null)"
if grep -qF 'EXISTING CHECKS THIS CHANGE MAKES WRONG' <<< "$_p4"; then
    assert_fail "[S4] no section without a block" "present"
else
    assert_pass "[S4] no section without a block"
fi
assert_contains "[S4] the other-tag rule stands" "$_p4" "never change, move or remove it"

print_test_section "S5: design is told"
assert_contains "[S5] design's instructions describe the supersedes block" \
    "$(cat "$REPO_ROOT/plugins/agent/design/plugin.sh")" 'supersedes block — one line per check'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
