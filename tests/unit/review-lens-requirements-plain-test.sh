#!/usr/bin/env bash
# tests/unit/review-lens-requirements-plain-test.sh — a review lens reads the
# change's requirements as sentences, not the acceptance block's raw keys (#2269).
#
# Why: lenses got the acceptance block verbatim — `SPEC-1[change]:`, `WIRING:`,
# `TESTFILES:` — keys written for the engine's parser, with no word on what the
# tags mean. A reviewer judging a change against requirements it cannot read
# judges the keys, not the requirements. Every lens still gets everything; it is
# rendered so a reader can use it.
#
# Note on order: this test was written after the review-lens change (an ordering
# slip, recorded in the #2269 PR); it was confirmed to fail against main's code.
#
# L1 [change] each requirement appears with what its tag means
# L2 [change] the WIRING file is named as "the existing file that calls the new code"
# L3 [change] no raw keys (`[change]:`, `WIRING:`, `TESTFILES:`) reach the lens
# L4 [guard]  each requirement's test files are still named
# L5 [change] (#2304, ADR-069) each status in plain words; a done one's evidence
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a review lens reads the requirements as sentences (#2269)"
setup_test_env "review-lens-requirements-plain"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" >/dev/null 2>&1

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'EOF'
# Design

```acceptance
SPEC-1[code]: the stage writes its result on every exit
SPEC-2[no-code]: the docs describe the result file
SPEC-3[done]: the dry run opens no PR evidence: plugins/agent/x/plugin.sh:12 tests/unit/z-test.sh
WIRING: plugins/agent/x/plugin.sh
TESTFILES:
SPEC-1: tests/unit/x-test.sh
SPEC-2: tests/unit/y-test.sh
```
EOF
printf '{"inputs":{"design":"%s"}}\n' "$D" > "$TEST_TEMP_DIR/si.json"
_ctx="$(ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/si.json" _rl_context "" 2>/dev/null)"

assert_contains "[L1] a [code] requirement says it is new behaviour" "$_ctx" "SPEC-1 (new behaviour):"
# #2304 (ADR-069): each status in plain words, and the evidence a done one names.
assert_contains "[L5] a [no-code] requirement says it changes no behaviour" "$_ctx" \
    "SPEC-2 (work that changes no behaviour):"
assert_contains "[L5] a [done] requirement says the code already does it" "$_ctx" \
    "SPEC-3 (already done — the code already does this): the dry run opens no PR"
assert_contains "[L5] ...and names what shows it" "$_ctx" \
    "shown by: plugins/agent/x/plugin.sh:12 tests/unit/z-test.sh"
if grep -qF 'must keep working' <<< "$_ctx"; then
    assert_fail "[L5] no requirement is called 'must keep working'" "found in the lens context"
else
    assert_pass "[L5] no requirement is called 'must keep working'"
fi
assert_contains "[L2] the WIRING file is named plainly" "$_ctx" "The existing file that calls the new code: plugins/agent/x/plugin.sh"
for _k in '[code]:' '[no-code]:' '[done]:' ' evidence: ' 'WIRING:' 'TESTFILES:'; do
    if grep -qF -- "$_k" <<< "$_ctx"; then
        assert_fail "[L3] the lens is not shown the raw key '$_k'" "found in the lens context"
    else
        assert_pass "[L3] the lens is not shown the raw key '$_k'"
    fi
done
assert_contains "[L4] SPEC-1's test file is named" "$_ctx" "checked by: tests/unit/x-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
