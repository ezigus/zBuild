#!/usr/bin/env bash
# tests/unit/issue-scoped-spec-tags-test.sh — acceptance tags carry the issue
# they belong to, so two issues' SPEC-3 can share one test file.
#
# Why: #1845 run 20260927202711-2342. Its design listed a shared integration
# test (deployed-template-e2e-test.sh) as a testfile; test-author's stale-tag
# step (#2174) treated every [SPEC-n] whose number was not in #1845's contract
# as stale and stripped #1328's [SPEC-1..10] from 26 assertions. Tag numbers
# were never unique across issues.
#
# The scheme ADDS to the old one and never overlaps it: a new tag reads
# [#<issue>/SPEC-<n>]; an old [SPEC-n] keeps its meaning and is never touched.
# `\[SPEC-[0-9]+\]` cannot match a new tag, and a new tag is matched exactly.
#
# T1 [change] acceptance_spec_tag makes [#<issue>/SPEC-n] under ZBUILD_ISSUE,
#             and the bare [SPEC-n] with no issue (a --goal run)
# T2 [change] coverage: only THIS issue's tag satisfies a SPEC — a legacy
#             [SPEC-3] or another issue's [#999/SPEC-3] does not
# T3 [change] the test-output scan (negctl/reachability) reads only this
#             issue's tagged lines
# T4 [change] the stale-tag step removes only THIS issue's stale tags; a legacy
#             tag and another issue's tag survive untouched
# T5 [change] test-author is shown the literal tag to write for each SPEC
# T6 [change] the build prompt names the same tags
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../scripts/lib/acceptance-coverage.sh
source "$REPO_ROOT/scripts/lib/acceptance-coverage.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh" 2>/dev/null || true

print_test_header "acceptance tags carry their issue: [#<issue>/SPEC-n]"
setup_test_env "issue-scoped-spec-tags"
unset ZBUILD_ACCEPTANCE_RUN_CMD 2>/dev/null || true
# A reserved test identity, never a real issue number (lint-test-identity).
_ID="$(zb_test_issue)"

REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO/tests"
DESIGN="$TEST_TEMP_DIR/design.md"
cat > "$DESIGN" <<'EOF'
# Design

## Acceptance

```acceptance
SPEC-3[change]: validate writes a v2 result
SPEC-4[change]: validate reports misconfigured
TESTFILES:
tests/shared-test.sh
```
EOF

print_test_section "T1: the tag"
assert_eq "[T1] under an issue" "[#${_ID}/SPEC-3]" "$(ZBUILD_ISSUE=${_ID} acceptance_spec_tag SPEC-3 2>/dev/null || true)"
assert_eq "[T1] with no issue (0)" "[SPEC-3]" "$(ZBUILD_ISSUE=0 acceptance_spec_tag SPEC-3 2>/dev/null || true)"
assert_eq "[T1] with no issue (unset)" "[SPEC-3]" "$(env -u ZBUILD_ISSUE bash -c 'source "$1/scripts/lib/acceptance-block.sh"; acceptance_spec_tag SPEC-3' _ "$REPO_ROOT" 2>/dev/null || true)"

print_test_section "T2: coverage counts only this issue's tag"
printf 'assert_eq "[SPEC-3] from #1328" a a\nassert_eq "[#999/SPEC-3] another issue" a a\n' > "$REPO/tests/shared-test.sh"
_rc=0; ZBUILD_ISSUE=${_ID} acceptance_coverage_spec_tagged "$DESIGN" "$REPO" SPEC-3 || _rc=$?
assert_eq "[T2] a legacy or foreign SPEC-3 does not cover #${_ID}'s SPEC-3" "1" "$_rc"
printf 'assert_eq "[#%s/SPEC-3] v2 result" a a\n' "$_ID" >> "$REPO/tests/shared-test.sh"
_rc=0; ZBUILD_ISSUE=${_ID} acceptance_coverage_spec_tagged "$DESIGN" "$REPO" SPEC-3 || _rc=$?
assert_eq "[T2] #${_ID}'s own tag covers it" "0" "$_rc"

print_test_section "T3: the test-output scan"
LOG="$TEST_TEMP_DIR/out.log"
printf '  ✗ [SPEC-3] #1328 assertion failing\n  ✓ [#%s/SPEC-3] v2 result\n' "$_ID" > "$LOG"
if declare -F _negctl_guard_log_check >/dev/null 2>&1; then
    _rc=0; ZBUILD_ISSUE=${_ID} _negctl_guard_log_check "$LOG" SPEC-3 || _rc=$?
    assert_eq "[T3] #${_ID}'s SPEC-3 reads as passing — the other issue's ✗ is not its line" "1" "$_rc"
else
    assert_fail "[T3] _negctl_guard_log_check is available" "not defined"
fi

print_test_section "T4: the stale-tag step"
TF="$REPO/tests/shared-test.sh"
cat > "$TF" <<EOF
assert_eq "[SPEC-9] legacy #1328 tag" a a
assert_eq "[#1328/SPEC-2] another issue" a a
assert_eq "[#${_ID}/SPEC-3] in this contract" a a
assert_eq "[#${_ID}/SPEC-7] stale, from an earlier #${_ID} design" a a
EOF
_ta_emit() { :; }
# shellcheck disable=SC1090
source <(sed -n '/^_ta_drop_stale_tags()/,/^}/p' "$REPO_ROOT/plugins/agent/test-author/plugin.sh")
ZBUILD_ISSUE=${_ID} _ta_drop_stale_tags "$DESIGN" "$REPO" 2>/dev/null || true
_body="$(cat "$TF")"
assert_contains "[T4] a legacy tag survives" "$_body" "[SPEC-9] legacy"
assert_contains "[T4] another issue's tag survives" "$_body" "[#1328/SPEC-2] another"
assert_contains "[T4] this contract's tag survives" "$_body" "[#${_ID}/SPEC-3] in this"
if grep -qF "[#${_ID}/SPEC-7]" "$TF"; then
    assert_fail "[T4] this issue's stale tag is removed" "still present"
else
    assert_contains "[T4] this issue's stale tag is removed, the assertion kept" "$_body" "stale, from an earlier"
fi

print_test_section "T5/T6: the prompts name the tag"
_ta_prompt_src="$(sed -n '/^test_author_run()/,/^}/p' "$REPO_ROOT/plugins/agent/test-author/plugin.sh")"
if grep -qF 'acceptance_spec_tag' <<< "$_ta_prompt_src"; then
    assert_pass "[T5] test-author builds each requirement's tag with acceptance_spec_tag"
else
    assert_fail "[T5] test-author builds each requirement's tag with acceptance_spec_tag" "not called in test_author_run"
fi
if grep -qF 'acceptance_spec_tag' "$REPO_ROOT/plugins/agent/build/lib/prompt.sh"; then
    assert_pass "[T6] the build prompt names tags with acceptance_spec_tag"
else
    assert_fail "[T6] the build prompt names tags with acceptance_spec_tag" "not called in prompt.sh"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
