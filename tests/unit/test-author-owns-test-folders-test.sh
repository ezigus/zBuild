#!/usr/bin/env bash
# tests/unit/test-author-owns-test-folders-test.sh — test-author owns the test
# folders (#2508, ADR-069 §11, ADR-030 §8).
#
# #1805 run 42556446368: test-author's new test needed a template nobody listed
# (tests/fixtures/templates/from-stage-combined-resume.yaml). Its commit took
# only design's listed test files, so the template was left uncommitted, build's
# scope check counted it as build's, and the run ended. Test-author now writes
# the tests and any helper file they need anywhere in the repository's test
# folders, and its commit takes every file it changed there.
#
# O1 the commit includes a helper file test-author created in a test folder
# O2 the commit includes the new test file found by its tag
# O3 a file it changed outside the test folders is not committed
# O4 the prompt says it writes the tests and their helper files in the test
#    folders, and nothing outside them
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "test-author owns the test folders (#2508)"
setup_test_env "test-author-owns-test-folders"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE
T1="$(acceptance_spec_tag TAOWN-1)"

# The author's model: writes the test (failing on the old code, as it must), a
# helper file the test reads, and — wrongly — a source file outside the tests.
route_to_model_loop() {
    cp "$2" "$TEST_TEMP_DIR/author-prompt"
    mkdir -p "$R/tests/fixtures/templates"
    printf '#!/usr/bin/env bash\nprintf "  ✗ %%s it holds\\n" "%s"\nexit 1\n' "$T1" > "$R/tests/new-test.sh"
    printf 'stages: [a, b]\n' > "$R/tests/fixtures/templates/helper.yaml"
    printf 'echo changed\n' >> "$R/scripts/tool.sh"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
route_to_model() { zb_test_check_ok "$2"; }

d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
mkdir -p "$A" "$R/tests" "$R/scripts"
( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
    && printf 'echo tool\n' > scripts/tool.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
cat > "$A/design.md" <<'MD'
# Design
```acceptance
TAOWN-1[code]: an empty input returns rc 1
  When: the tool runs with no input
  Then: it exits 1
WIRING: none
```
MD
export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1

COMMITTED="$(git -C "$R" show --name-only --format= HEAD 2>/dev/null)"
assert_contains "[O1] the helper file test-author created in a test folder is committed" \
    "$COMMITTED" "tests/fixtures/templates/helper.yaml"
assert_contains "[O2] the new test file is committed" "$COMMITTED" "tests/new-test.sh"
if grep -qxF scripts/tool.sh <<< "$COMMITTED"; then
    assert_fail "[O3] a file changed outside the test folders is not committed" "scripts/tool.sh is in the commit"
else
    assert_pass "[O3] a file changed outside the test folders is not committed"
fi
assert_contains "[O3] ...it is left as a change in the working tree" \
    "$(git -C "$R" status --porcelain 2>/dev/null)" " M scripts/tool.sh"

_AP="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt" 2>/dev/null)"
assert_contains "[O4] the prompt says it writes the tests and the files they need in the test folders" "$_AP" \
    "Write the tests, and any file they need, in the repository's test folders"
assert_contains "[O4] ...and names the test folders" "$_AP" "tests/*"
assert_contains "[O4] ...and nothing outside them" "$_AP" "Change no file outside the test folders"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
