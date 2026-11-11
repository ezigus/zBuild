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
# #2520 (ADR-069 §11): a SPEC's tests are found only in files the branch wrote
# (#2517), so the issue number is no longer needed: a tag is the id alone, and
# this issue's old [#<issue>/<id>] tags are still read.
#
# T1 [code]   acceptance_spec_tag makes [<id>], under an issue or not
# T2 [code]   coverage: the id-alone tag and this issue's old tag satisfy a
#             SPEC; another issue's [#999/SPEC-3] does not
# T3 [code]   the test-output scan reads both, and not another issue's line
# T4 [code]   the stale-tag step removes a stale tag only on a line this branch
#             added; every tag on a line the default branch has survives
# T5 [change] test-author is shown the literal tag to write for each SPEC
# T6 [change] the build prompt names the same tags
# T7 [change] ...and so does the design prompt's tagging rule (review on #2214)
# T8 [code]   design numbers a new id after the highest its letters have in the
#             repository's tests, and never says a tag holds the issue's number
# T9 [code]   test-author: a tag on a line the branch added is its own
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../scripts/lib/acceptance-coverage.sh
source "$REPO_ROOT/scripts/lib/acceptance-coverage.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh" 2>/dev/null || true

print_test_header "a tag is the id alone; the stale-tag step touches only the branch's lines"
setup_test_env "issue-scoped-spec-tags"
unset ZBUILD_ACCEPTANCE_RUN_CMD 2>/dev/null || true
# A reserved test identity, never a real issue number (lint-test-identity).
_ID="$(zb_test_issue)"

REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO/tests"
# #2508: a SPEC's tests are found in a repository's test folders, by tag.
git -C "$REPO" init -q
DESIGN="$TEST_TEMP_DIR/design.md"
cat > "$DESIGN" <<'EOF'
# Design

## Acceptance

```acceptance
SPEC-3[change]: validate writes a v2 result
SPEC-4[change]: validate reports misconfigured
```
EOF

print_test_section "T1: the tag"
assert_eq "[T1] under an issue, the id alone" "[SPEC-3]" "$(ZBUILD_ISSUE=${_ID} acceptance_spec_tag SPEC-3 2>/dev/null || true)"
assert_eq "[T1] with no issue (0)" "[SPEC-3]" "$(ZBUILD_ISSUE=0 acceptance_spec_tag SPEC-3 2>/dev/null || true)"
assert_eq "[T1] with no issue (unset)" "[SPEC-3]" "$(env -u ZBUILD_ISSUE bash -c 'source "$1/scripts/lib/acceptance-block.sh"; acceptance_spec_tag SPEC-3' _ "$REPO_ROOT" 2>/dev/null || true)"

print_test_section "T2: coverage"
printf 'assert_eq "[#999/SPEC-3] another issue" a a\n' > "$REPO/tests/shared-test.sh"
_rc=0; ZBUILD_ISSUE=${_ID} acceptance_coverage_spec_tagged "$DESIGN" "$REPO" SPEC-3 || _rc=$?
assert_eq "[T2] another issue's old tag does not cover SPEC-3" "1" "$_rc"
printf 'assert_eq "[#%s/SPEC-3] v2 result" a a\n' "$_ID" >> "$REPO/tests/shared-test.sh"
_rc=0; ZBUILD_ISSUE=${_ID} acceptance_coverage_spec_tagged "$DESIGN" "$REPO" SPEC-3 || _rc=$?
assert_eq "[T2] this issue's old [#<issue>/SPEC-3] tag still covers it" "0" "$_rc"
printf 'assert_eq "[#999/SPEC-3] another issue" a a\nassert_eq "[SPEC-3] v2 result" a a\n' > "$REPO/tests/shared-test.sh"
_rc=0; ZBUILD_ISSUE=${_ID} acceptance_coverage_spec_tagged "$DESIGN" "$REPO" SPEC-3 || _rc=$?
assert_eq "[T2] the id-alone tag covers it" "0" "$_rc"

print_test_section "T3: the test-output scan"
LOG="$TEST_TEMP_DIR/out.log"
if declare -F _negctl_spec_log_check >/dev/null 2>&1; then
    printf '  ✗ [#999/SPEC-3] another issue failing\n  ✓ [SPEC-3] v2 result\n' > "$LOG"
    _rc=0; ZBUILD_ISSUE=${_ID} _negctl_spec_log_check "$LOG" SPEC-3 || _rc=$?
    assert_eq "[T3] SPEC-3 reads as passing — another issue's ✗ is not its line" "1" "$_rc"
    printf '  ✗ [#%s/SPEC-3] v2 result failing\n' "$_ID" > "$LOG"
    _rc=0; ZBUILD_ISSUE=${_ID} _negctl_spec_log_check "$LOG" SPEC-3 || _rc=$?
    assert_eq "[T3] ...and this issue's old tag is still read" "0" "$_rc"
else
    assert_fail "[T3] _negctl_spec_log_check is available" "not defined"
fi

print_test_section "T4: the stale-tag step touches only lines the branch added"
# #2520 (ADR-069 §11): on #1805 run 42817975218 the step stripped 13 tags of
# sample text from five engine tests the issue never wrote. A tag on a line
# the default branch has is never touched, whatever it is.
SR="$TEST_TEMP_DIR/stale"; mkdir -p "$SR/tests"
git -C "$SR" init -q -b main; git -C "$SR" config user.email t@t; git -C "$SR" config user.name t
cat > "$SR/tests/shared-test.sh" <<EOF
assert_eq "[SPEC-9] legacy tag" a a
assert_eq "[#1328/SPEC-2] another issue" a a
assert_eq "[#${_ID}/SPEC-7] on the default branch" a a
printf '%s' 'sample text: [#1805/SPEC-3] and [#${_ID}/SPEC-13]'
EOF
git -C "$SR" add -A; git -C "$SR" commit -qm base
git -C "$SR" checkout -qb "issue-${_ID}"
cat >> "$SR/tests/shared-test.sh" <<EOF
assert_eq "[SPEC-3] in this contract" a a
assert_eq "[SPEC-7] stale, added by this branch" a a
assert_eq "[#${_ID}/SPEC-8] stale old form, added by this branch" a a
EOF
_ta_emit() { :; }
# shellcheck disable=SC1090
source <(sed -n '/^_ta_drop_stale_tags()/,/^}/p' "$REPO_ROOT/plugins/agent/test-author/plugin.sh")
ZBUILD_ISSUE=${_ID} _ta_drop_stale_tags "$DESIGN" "$SR" 2>/dev/null || true
_body="$(cat "$SR/tests/shared-test.sh")"
assert_contains "[T4] a legacy tag on the default branch survives" "$_body" "[SPEC-9] legacy"
assert_contains "[T4] another issue's tag survives" "$_body" "[#1328/SPEC-2] another"
assert_contains "[T4] this issue's old tag on the default branch survives" "$_body" "[#${_ID}/SPEC-7] on the default"
assert_contains "[T4] sample text in a line the branch did not write survives, this issue's number and all" "$_body" "[#1805/SPEC-3] and [#${_ID}/SPEC-13]"
assert_contains "[T4] this contract's tag survives" "$_body" "[SPEC-3] in this"
if grep -qF "[SPEC-7] stale, added" <<< "$_body" || grep -qF "[#${_ID}/SPEC-8]" <<< "$_body"; then
    assert_fail "[T4] a stale tag on a line the branch added is removed" "still present"
else
    assert_contains "[T4] a stale tag on a line the branch added is removed, the assertion kept" "$_body" "stale old form, added"
fi

# With no base in common with the default branch, no line is the branch's own.
git -C "$SR" checkout -q --orphan lone && git -C "$SR" commit -qam lone
printf 'assert_eq "[SPEC-7] new, not committed" a a\n' > "$SR/tests/new-test.sh"
declare -A _t4l=(); zb_test_folder_branch_lines_v _t4l "$SR"
assert_eq "[T4] with no common base, no line is the branch's" "0" "${#_t4l[@]}"

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

_design_src="$(sed -n '/You name no files/,/checked on its own/p' "${ZB_DESIGN_PLUGIN:-$REPO_ROOT/plugins/agent/design/plugin.sh}")"
_design_ids="$(sed -n '/The id describes the SPEC/,/need no REMOVED line/p' "$REPO_ROOT/plugins/agent/design/plugin.sh")"
assert_contains "[T8] design numbers a new id after the highest its letters have in the repository's tests" "$_design_ids" \
    "one more than the highest number already used"
assert_contains "[T8] ...with an example" "$_design_ids" "the new one is \${_DCK_ID_PREFIX}LOOP-4"
assert_contains "[T8] ...and says the id is the tag its test carries" "$_design_ids" "The id is also the tag its test"
if grep -qF "this issue's number" <<< "$_design_src$_design_ids"; then
    assert_fail "[T8] design no longer says a tag holds the issue's number" "found"
else assert_pass "[T8] design no longer says a tag holds the issue's number"; fi
_ta_src="$(sed -n '/^test_author_run()/,/^}/p' "$REPO_ROOT/plugins/agent/test-author/plugin.sh")"
assert_contains "[T9] test-author: a tag on a line this branch added is its own" "$_ta_src" "A tag on a line this branch added is yours"
if grep -qF "issue's number" <<< "$_ta_src"; then
    assert_fail "[T9] test-author is not told a tag carries the issue's number" "found"
else assert_pass "[T9] test-author is not told a tag carries the issue's number"; fi
if grep -qF 'acceptance_spec_tag' <<< "$_design_src$(sed -n '/The id describes the SPEC/,/need no REMOVED line/p' "$REPO_ROOT/plugins/agent/design/plugin.sh")"; then
    assert_pass "[T7] the design prompt's tagging rule names the tag with acceptance_spec_tag"
else
    assert_fail "[T7] the design prompt's tagging rule names the tag with acceptance_spec_tag" "rule: ${_design_src:0:200}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
