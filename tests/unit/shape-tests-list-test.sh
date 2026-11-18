#!/usr/bin/env bash
# tests/unit/shape-tests-list-test.sh — a change to a run-shaping file always
# runs the run's shape tests, and nothing demands a shape test be edited
# (#2556, ADR-040).
#
# Why: on #1764 run 43772987273 the shape floor listed 7 files as needing an
# edit that needed none. It looked for the run's test results in the test
# stage's input list, written before the suite ran, so on test's first run it
# had no evidence and listed every unedited file; two of the seven matched only
# because the check's own test data looks like an order assertion. The suite
# already says whether a shape test still holds — the one thing it cannot do
# alone is make sure the shape tests run when a rerun picks only some files.
#
# ST1 [change] a targeted run after a change to a file on
#              config/shape-change-paths.txt holds every test on
#              config/shape-tests.txt
# ST2 [guard]  a change to a file on neither list adds none of them
# ST3 [change] every file on config/shape-tests.txt exists
# ST4 [change] the shape floor is gone: its check, its library, its outputs and
#              its events
# ST5 [change] tests/golden/full-pipeline/event-sequence.golden, which no test
#              read, is gone
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a run-shaping change always runs the shape tests (#2556)"
setup_test_env "shape-tests-list"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh" >/dev/null 2>&1

# A repository with the engine's two lists, the shape tests, and one more test.
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/config" "$R/core/pipeline" "$R/tests/unit" "$R/scripts"
cp "$REPO_ROOT/config/shape-change-paths.txt" "$REPO_ROOT/config/shape-tests.txt" "$R/config/" 2>/dev/null
: > "$R/core/pipeline/runner.sh"; : > "$R/scripts/other.sh"
SHAPE=()
while IFS= read -r l; do
    l="${l%%#*}"; l="${l//[[:space:]]/}"; [[ -n "$l" ]] || continue
    SHAPE+=("$l"); mkdir -p "$R/$(dirname "$l")"; printf '#!/usr/bin/env bash\n' > "$R/$l"
done < "$REPO_ROOT/config/shape-tests.txt" 2>/dev/null
printf '#!/usr/bin/env bash\n' > "$R/tests/unit/unrelated-test.sh"

print_test_section "ST1/ST2: the targeted set"
_set="$(ZBUILD_TEST_CHANGED_FILES="core/pipeline/runner.sh" _test_compute_target_files "$R" 2>/dev/null)"
if [[ ${#SHAPE[@]} -eq 0 ]]; then
    assert_fail "[ST1] config/shape-tests.txt lists the shape tests" "it lists none, or is missing"
else
    _miss=""
    for t in "${SHAPE[@]}"; do grep -qxF "$t" <<< "$_set" || _miss+=" $t"; done
    assert_eq "[ST1] a runner.sh change: every shape test is in the targeted set" "" "$_miss"
fi
_set="$(ZBUILD_TEST_CHANGED_FILES="scripts/other.sh" _test_compute_target_files "$R" 2>/dev/null)"
_got=""
for t in ${SHAPE[@]+"${SHAPE[@]}"}; do grep -qxF "$t" <<< "$_set" && _got+=" $t"; done
assert_eq "[ST2] a change to a file on neither list adds none of them" "" "$_got"

print_test_section "ST3: the list names real files"
_gone=""
for t in ${SHAPE[@]+"${SHAPE[@]}"}; do [[ -f "$REPO_ROOT/$t" ]] || _gone+=" $t"; done
assert_eq "[ST3] every file on config/shape-tests.txt exists" "" "$_gone"

print_test_section "ST4/ST5: the shape floor is gone"
assert_file_not_exists "[ST4] the shape floor's check is gone" "$REPO_ROOT/plugins/tool/test/lib/shape-floor-check.sh"
assert_file_not_exists "[ST4] ...and its library" "$REPO_ROOT/scripts/lib/shape-floor.sh"
assert_eq "[ST4] ...and its outputs and events in test's manifest" "0" \
    "$(grep -c 'shape.floor' "$REPO_ROOT/plugins/tool/test/manifest.yaml" || true)"
assert_eq "[ST4] ...and its events in the event schema" "0" \
    "$(grep -c 'shape_floor' "$REPO_ROOT/config/event-schema.json" || true)"
assert_file_not_exists "[ST5] the golden no test read is gone" "$REPO_ROOT/tests/golden/full-pipeline/event-sequence.golden"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
