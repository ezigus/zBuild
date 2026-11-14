#!/usr/bin/env bash
# tests/unit/design-steps-code-only-test.sh — design's work steps are the code
# work; the tests are test-author's (ADR-071 §1 amendment 2026-11-14, which
# retires #2458's step topics; ADR-069 §11).
#
# Why: on #1769 run 43517034037 design's steps named the folder the tests went
# in (`plugins/agent/build/tests/`), test-author put them there, and the scope
# lens — seeing design had chosen it — sent "the tests are in a file the issue
# did not name" to design as `fix: design`. Design changed its step; test-author,
# shown its tests as already written, answered "not mine"; the tests never
# moved. Two design tries were also spent rewording test steps. Design decides
# the change and what must be true (its SPECs); which tests, in which files, and
# how they are written is test-author's.
#
# S1 [change] a step that names a file or folder in the test folders fails
#             design's check, naming it and saying the tests are test-author's
# S2 [change] a step that names only code passes that check
# S3 [change] design-steps.json holds each step's words and areas, in order
# S4 [change] build's prompt holds the design's steps
# T5 [change] build's prompt gives it no file list (#2508: it may change any
#             file outside the test folders), so it names no test file
# S5 [change] test-author's prompt holds no step of the design
# S6 [change] test-author's prompt holds the issue's text, so the files the
#             issue names for its tests are in front of it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's steps are the code work; the tests are test-author's"
setup_test_env "design-steps-code-only"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# ── S1 / S2: design's check reads each step's areas ──────────────────────────
CR="$TEST_TEMP_DIR/check-repo"; mkdir -p "$CR/core" "$CR/tests/unit"
( cd "$CR" && git init -q && git config user.email t@t && git config user.name t \
    && echo 'a() { :; }' > core/a.sh && echo '# t' > tests/unit/a-test.sh \
    && git add -A && git commit -q -m seed ) >/dev/null 2>&1
_draft() {   # <file> <steps lines…>
    local f="$1"; shift
    { printf '# Design\n\n## Decision\nMinimal.\n\n```steps\n'
      printf '%s\n' "$@"
      printf '```\n\n```acceptance\nDSWORK-1[no-code]: works\nWIRING: none\n```\n'; } > "$f"
}
_has_step_is_test() {   # <area> — 0 when a STEP_IS_TEST violation names it
    local v
    for v in "${_DESIGN_VIOLATIONS[@]}"; do [[ "$v" == "STEP_IS_TEST $1 "* ]] && return 0; done
    return 1
}
_draft "$TEST_TEMP_DIR/mixed.md" "- guard the read in a.sh | areas: core/a.sh" \
    "- add the test | areas: tests/unit/a-test.sh" "- put the checks here | areas: tests/unit/"
_design_checks "$TEST_TEMP_DIR/mixed.md" "$CR" ""
if _has_step_is_test tests/unit/a-test.sh; then assert_pass "[S1] a step naming a test file fails design's check"
else assert_fail "[S1] a step naming a test file fails design's check" "violations: ${_DESIGN_VIOLATIONS[*]}"; fi
if _has_step_is_test tests/unit/; then assert_pass "[S1] ...and so does a step naming a test folder"
else assert_fail "[S1] ...and so does a step naming a test folder" "violations: ${_DESIGN_VIOLATIONS[*]}"; fi
if _has_step_is_test core/a.sh; then assert_fail "[S1] ...but not the step on code" "core/a.sh was flagged"
else assert_pass "[S1] ...but not the step on code"; fi
_plain=""
for _v in "${_DESIGN_VIOLATIONS[@]}"; do [[ "$_v" == STEP_IS_TEST* ]] && { _plain="$(_dck_plain "$_v")"; break; }; done
assert_contains "[S1] the finding names the file" "$_plain" "tests/unit/a-test.sh"
assert_contains "[S1] ...and says the tests are test-author's" "$_plain" "test-author"

_draft "$TEST_TEMP_DIR/code.md" "- guard the read in a.sh | areas: core/a.sh"
_design_checks "$TEST_TEMP_DIR/code.md" "$CR" ""
_sit=0; for _v in "${_DESIGN_VIOLATIONS[@]}"; do [[ "$_v" == STEP_IS_TEST* ]] && _sit=1; done
assert_eq "[S2] a design whose steps name only code passes that check" "0" "$_sit"

# ── S3: the steps design writes ──────────────────────────────────────────────
route_to_model() {
    local _bt='```' _t; _t="$(zb_test_prompt_write_path "$2")"
    if [[ -n "$_t" ]]; then
        mkdir -p "$(dirname "$_t")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%ssteps\n- guard the read in a.sh | areas: core/a.sh\n- export the flag and check it | areas: core/b.sh, core/c.sh\n%s\n\n%sacceptance\nDSWORK-1[no-code]: works\nWIRING: none\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" > "$_t"
    fi
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }

D="$TEST_TEMP_DIR/run"; ST="$D/state"; AD="$ST/artifacts"
mkdir -p "$AD"; git -C "$D" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$ST/scope-manifest.md"
export ZBUILD_REPO_ROOT="$D" ZBUILD_EVENTS_JSONL="$ST/events.jsonl" ZBUILD_EVENTS_DIR="$ST"
: > "$ZBUILD_EVENTS_JSONL"
_design_stage_run_inner "$ST/scope-manifest.md" "$AD/design.md" "$AD" >/dev/null 2>&1
STEPS="$AD/design-steps.json"
assert_eq "[S3] design-steps.json holds each step's words and areas, in order" \
    '[{"id":"step-1","description":"guard the read in a.sh","areas":["core/a.sh"]},{"id":"step-2","description":"export the flag and check it","areas":["core/b.sh","core/c.sh"]}]' \
    "$(jq -c '.steps' "$STEPS" 2>/dev/null || echo MISSING)"

# ── S4 / T5: build's prompt ──────────────────────────────────────────────────
BST="$TEST_TEMP_DIR/build-run/state"; BAD="$BST/artifacts"; mkdir -p "$BAD"
cp "$AD/design.md" "$STEPS" "$BAD/"; cp "$ST/scope-manifest.md" "$BST/"
(
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh"
    route_to_model_loop() {
        _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
        _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0; _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
        return 0
    }
    _route_resolve_max_iterations() { echo 3; }
    _route_loop_close_final_banner() { return 0; }
    apply_scope_redaction() { [[ -f "$1" ]] && cp "$1" "$2"; return 0; }
    R="$TEST_TEMP_DIR/build-repo"; mkdir -p "$R"
    ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
        && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$R" ZBUILD_STATE_DIR="$BST" ZBUILD_ARTIFACT_DIR="$BAD"
    unset ZBUILD_CYCLE_ITER ZBUILD_SCOPE_ALLOWLIST
    _build_stage_run_inner "$BST/scope-manifest.md" "$BAD/design-steps.json" "$BAD/diff.patch" \
        "$BAD/build-summary.json" "$BAD" >/dev/null 2>&1
) || true
_bp="$(cat "$BAD/build-prompt.txt" 2>/dev/null)"
assert_contains "[S4] build's prompt holds the design's first step" "$_bp" "guard the read in a.sh"
assert_contains "[S4] ...and its second" "$_bp" "export the flag and check it"
_lacks "[T5] build's prompt gives it no file list" "$_bp" "### Scope"
_lacks "[T5] ...and names no test file" "$_bp" "tests/acc-test.sh"

# ── S5 / S6: test-author's prompt ────────────────────────────────────────────
# A design-steps.json written before this change, with a step on a test file,
# is still not shown to test-author: no step of the design is.
printf '%s\n' '{"title":"Design","steps":[{"id":"step-1","description":"set the flag in the test","areas":["tests/acc-test.sh"],"topic":"tests"}]}' \
    > "$AD/design-steps.json"
printf '%s\n' '{"result_contract":3,"outcome":"pass","data":{"issue_text":"ISSUE-WORDS-1769: the tests go in tests/unit/acc-test.sh"}}' \
    > "$AD/intake-result.json"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    _P="$TEST_TEMP_DIR/ta-prompt.txt"
    route_to_model() {
        if zb_test_check_ok "$2"; then
            return 0
        fi
        printf '%s' "$2" > "$_P"; printf 'authored\n'; return 0
    }
    resolve_tier() { printf 'T2'; }
    route_to_model_loop() { local _p; _p="$(cat "$2")"; route_to_model "$1" "$_p" >/dev/null; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; return 0; }
    TR="$TEST_TEMP_DIR/ta-repo"; mkdir -p "$TR/tests"
    printf '%s\n' 'assert_eq "[DSWORK-1] placeholder" "1" "$got"' > "$TR/tests/acc-test.sh"
    ( cd "$TR" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$TR" ZBUILD_ARTIFACT_DIR="$AD" ZBUILD_STATE_DIR="$ST"
    printf '{}' > "$ST/pipeline-state.json"
    test_author_run "test-author" "$ST/pipeline-state.json" >/dev/null 2>&1
) || true
_tp="$(cat "$TEST_TEMP_DIR/ta-prompt.txt" 2>/dev/null)"
assert_contains "[S5] test-author's prompt was written" "$_tp" "REQUIREMENTS:"
_lacks "[S5] test-author's prompt holds no step of the design" "$_tp" "set the flag in the test"
assert_contains "[S6] test-author's prompt holds the issue's text" "$_tp" "ISSUE-WORDS-1769: the tests go in tests/unit/acc-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
