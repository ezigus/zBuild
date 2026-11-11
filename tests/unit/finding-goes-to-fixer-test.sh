#!/usr/bin/env bash
# tests/unit/finding-goes-to-fixer-test.sh — a finding reaches the stages that
# can fix it, once (#2491, ADR-071 §1 §3, ADR-068 §3).
#
# Why: on #1805 run 42439063480
# - every lens finding about code went to test-author too, under the one topic
#   code-findings, and it answered the same 11 findings "not mine", "wrong" and
#   "done" across three tries, though it can change none of that code;
# - each one reached it twice: as a numbered finding, and again in the lens's
#   summary, which lists every finding;
# - test-author's check found the test could not meet DSCMBR-1's Given, which
#   only design can rewrite, but design takes requirement-findings and the
#   check's findings were code-findings: design could never have been shown it.
#
# F1 [change] a lens finding the code must fix reaches build, not test-author
# F2 [guard]  one a test must fix reaches test-author, and build
# F3 [change] test-author and build are shown each lens finding once: the
#             lens's summary, verdict file and replies reach no stage
# F4 [change] design is shown what test-author's check found
#
# #1805 run 42523805245: two topics each carried two kinds of item, so a finding
# reached a stage that could not fix it.
# - `change` was the diff and the lens findings the code must fix: issue-acceptance
#   takes `change` for the diff, was shown all 12 lens findings, and answered them;
# - `requirement-findings` was what the code does not meet and what test-author's
#   check found wrong in a test: build was shown "DSFRSH-2's test never asserts no
#   stage.skip", a test only test-author may edit.
# F5 [change] a finding the code must fix (lens, or a failing file that is not
#             the design's test) reaches build only: not issue-acceptance
# F6 [change] test-author's check finding is not shown to build; [guard] it still
#             reaches design and test-author
#
# #1805 run 43093018140: issue-acceptance's unasked edits to 5 test files went to
# build only, which may not change a test; test-author was never shown them.
# F7 [change] an unasked part in a test file reaches test-author (#2523); one
#             in any other file still does not
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a finding reaches the stages that can fix it, once (#2491)"
setup_test_env "finding-goes-to-fixer"
unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1 \
    || assert_fail "simple.yaml loads" "load_template failed"
PROOT="$REPO_ROOT/plugins"
STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_ARTIFACT_DIR="$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1

# The lens's files, written by the lens itself (#1799): its model answers with
# one finding the code must fix and one a test must fix.
printf 'diff --git a/a.sh b/a.sh\n+x=1\n' > "$ART/diff.patch"
printf 'scope: all\n' > "$TEST_TEMP_DIR/scope-manifest.md"
_f() { printf '{"quote":"x=1","file":"a.sh","category":"x","severity":"high","line":1,"message":"%s","introduced":true,"fix":"%s"}' "$1" "$2"; }
_FINDINGS="[$(_f "CODE-FIX the read is unchecked" code),$(_f "TEST-FIX the test sets a value the engine never writes" test)]"
route_to_model() { printf '%s' "{\"score\":3,\"findings\":$_FINDINGS}"; return 0; }
_TPL_STAGE_FAIL_ON_review_lenses="medium high critical" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=correctness \
    _review_lens_run_inner correctness "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-correctness.json" "$ART" >/dev/null 2>&1 || true
_update_stage_status "$STATE/pipeline-state.json" review_lenses complete

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}
_pw() {   # <stage> — its Previous work, from the index the engine writes for it
    local idx; idx="$(_inputs_resolve_stage "$1" "$PROOT" "$STATE")"
    _stage_block_previous_work "$1" "$STATE" "$PROOT" "$idx" ""
}
_n() { grep -cF -- "$2" <<< "$1" || true; }
TA="$(_pw test-author)"
BUILD="$(_pw build)"

# ── F1 / F2 ──────────────────────────────────────────────────────────────────
print_test_section "F1/F2: each lens finding goes by what fixes it"
assert_contains "[F1] build is shown the finding the code must fix" "$BUILD" "CODE-FIX the read is unchecked"
assert_not_contains "[F1] ...and test-author is not" "$TA" "CODE-FIX"
assert_contains "[F2] test-author is shown the finding a test must fix" "$TA" "correctness lens, high: TEST-FIX"
assert_contains "[F2] ...as the lens's code output's finding" "$TA" "lens-correctness-code finding"
assert_contains "[F2] ...and so is build" "$BUILD" "TEST-FIX the test sets a value the engine never writes"

# ── F3 ───────────────────────────────────────────────────────────────────────
print_test_section "F3: once each"
assert_eq "[F3] test-author is shown the test finding once" "1" "$(_n "$TA" "TEST-FIX")"
assert_eq "[F3] build is shown the code finding once" "1" "$(_n "$BUILD" "CODE-FIX")"
assert_not_contains "[F3] the lens's summary reaches no stage" "$BUILD" "review-lens-correctness"
assert_not_contains "[F3] ...nor its replies" "$BUILD" "lens-correctness-reply.txt"

# ── F4 ───────────────────────────────────────────────────────────────────────
print_test_section "F4: design is shown what test-author's check found"
stage_result_write "$ART/test-author-result.json" unusable "1 finding about its assertions is open" \
    '{"findings":[{"n":1,"text":"DSCMBR-1: the Given says in-progress; the engine writes aborted [FIX IN TEST: …]"}]}' >/dev/null
_update_stage_status "$STATE/pipeline-state.json" test-author complete
assert_contains "[F4] design is shown test-author's check finding" "$(_pw design)" \
    "test-author finding 1 (opened by test-author): DSCMBR-1: the Given says in-progress"

# ── F5 ───────────────────────────────────────────────────────────────────────
print_test_section "F5: a finding the code must fix reaches build only (#1805 run 42523805245)"
IA="$(_pw issue-acceptance)"
assert_not_contains "[F5] issue-acceptance is not shown the lens finding the code must fix" "$IA" "CODE-FIX"
# shellcheck source=../../plugins/tool/test/lib/findings.sh
source "$REPO_ROOT/plugins/tool/test/lib/findings.sh"
_tf="$(printf 'lib/other.sh\tOTHER-FILE fails: not one of the design test files\n' | _test_findings_by_owner "" | stage_findings_json)"
stage_result_write "$ART/test-results.json" fail "1 file failed" "{\"findings\":$_tf}" >/dev/null
_update_stage_status "$STATE/pipeline-state.json" test complete
assert_contains "[F5] build is shown a failing file that is not the design's test" "$(_pw build)" "OTHER-FILE fails"
assert_not_contains "[F5] ...and issue-acceptance is not" "$(_pw issue-acceptance)" "OTHER-FILE fails"

# ── F6 ───────────────────────────────────────────────────────────────────────
print_test_section "F6: test-author's check finding goes to design and test-author, not build"
assert_not_contains "[F6] build is not shown test-author's check finding" "$(_pw build)" "DSCMBR-1: the Given says in-progress"
assert_contains "[F6] test-author is shown it" "$(_pw test-author)" "test-author finding 1"
assert_contains "[F6] ...and design" "$(_pw design)" "DSCMBR-1: the Given says in-progress"

# ── F7 ───────────────────────────────────────────────────────────────────────
print_test_section "F7: an unasked part in a test file reaches test-author (#2523)"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
_R7="$TEST_TEMP_DIR/repo7"; mkdir -p "$_R7/tests/unit" "$_R7/lib"
printf 'assert_eq "UNASKED-TEST shown as code" x y\n' > "$_R7/tests/unit/r-test.sh"
printf 'UNASKED_CODE=1\n' > "$_R7/lib/r.sh"
bad=() _IA_UNASKED=() _IA_QUOTED=() _IA_ANSWERS=()
_ia_parse_unasked 'it changes an old test | WHY: nobody asks | QUOTE: tests/unit/r-test.sh | assert_eq "UNASKED-TEST shown as code" x y' "$_R7"
_ia_parse_unasked 'it adds a flag | WHY: nobody asks | QUOTE: lib/r.sh | UNASKED_CODE=1' "$_R7"
_ia_write "$ART" fail "2 parts no requirement asks for" '[]' '[]' '' "$(_ia_json_list "${_IA_UNASKED[@]}")"
_update_stage_status "$STATE/pipeline-state.json" issue-acceptance complete
TA7="$(_pw test-author)"
assert_contains "[F7] test-author is shown the unasked part in a test file" "$TA7" "UNASKED-TEST shown as code"
assert_not_contains "[F7] ...and not the one in another file" "$TA7" "UNASKED_CODE=1"
assert_contains "[F7] build is still shown the one in another file" "$(_pw build)" "UNASKED_CODE=1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
