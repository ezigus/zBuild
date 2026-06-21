#!/usr/bin/env bash
# Tests (#613): sharpened LOOP_COMPLETE sentinel rule in build prompt.
#
# The old wording — "When the implementation is complete and tests would
# pass, emit LOOP_COMPLETE" — failed to cover the case where the branch is
# already done before iter 1. The LLM read "complete" as "I just completed"
# and kept iterating empty-handed. The new wording explicitly covers the
# already-done case, telling the LLM to check git log/diff and emit the
# sentinel immediately when there is nothing left to do.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build prompt LOOP_COMPLETE rule (#613)"
setup_test_env "build-prompt-loop-complete-rule"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Render the INSTRUCTIONS section with a sample plan.files scope.
out="$(_build_compose_instructions "src/foo.sh,src/bar.sh")"

# R1: section header still present.
assert_contains "R1: section header '### Completion sentinel' present" \
    "$out" "### Completion sentinel"

# R2: the sharpened wording covers the already-done case.
assert_contains "R2: prompt instructs LLM to emit sentinel whether just finished OR already done" \
    "$out" "whether you just finished it OR"

# R3: explicit "already done" guidance referencing git log / diff.
assert_contains "R3: prompt names git log + git diff as the already-done check" \
    "$out" "git log"
assert_contains "R3: prompt names git diff for the gap check" \
    "$out" "git diff"

# R4: directive against pointless iteration.
assert_contains "R4: prompt forbids iterating when nothing left to do" \
    "$out" "Do NOT keep iterating"

# R5: old wording must be gone — "and tests would pass" was the narrow phrasing.
if grep -qF "tests would pass" <<< "$out"; then
    assert_fail "R5: old narrow wording 'tests would pass' must be removed" \
        "found legacy phrasing"
else
    assert_pass "R5: legacy 'tests would pass' phrasing removed"
fi

# R6: the literal sentinel string LOOP_COMPLETE still appears.
assert_contains "R6: literal LOOP_COMPLETE sentinel name present" \
    "$out" "LOOP_COMPLETE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
