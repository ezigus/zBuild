#!/usr/bin/env bash
# tests/unit/design-step-topics-test.sh — design's work steps carry a topic, as
# findings do, so a step reaches the stage that may do it (#2458, ADR-071 §1/§2,
# ADR-067 §6).
#
# Why: on #1805 (run 41489923219) design's step "add `export
# _ZBUILD_RESUME_ACTIVE=true` to resume-loop-state-test.sh" — a test file of the
# design's own acceptance contract — went to build, which may not edit those
# files, and never to test-author. Build found the code fix, saw it turn that
# test red, and spent five tries without an edit.
#
# T1 [change] a step that touches only the design's test files is `tests`; a
#             step that touches code, or a test file outside the contract (a
#             golden, an older test), is `change`
# T2 [change] a step that touches both is split: its test files become a `tests`
#             step, the rest a `change` step, each with the same description
# T3 [change] build's prompt holds the `change` steps and no `tests` step
# T4 [change] test-author's prompt holds the `tests` steps and no `change` step
# T5 [change] build's list of files it may touch does not list the design's test
#             files, which it may not touch (ADR-067 §6: never tell a stage to
#             do what it may not do)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design's work steps reach the stage that may do them (#2458)"
setup_test_env "design-step-topics"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# ── T1 / T2: design labels its steps ─────────────────────────────────────────
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

route_to_model() {
    local _bt='```' _t; _t="$(zb_test_prompt_write_path "$2")"
    if [[ -n "$_t" ]]; then
        mkdir -p "$(dirname "$_t")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\ncore/a.sh\ncore/b.sh\ntests/acc-test.sh\ntests/golden/g.golden\n%s\n\n%ssteps\n- guard the read in a.sh | areas: core/a.sh\n- set the flag in the test | areas: tests/acc-test.sh\n- export the flag and check it | areas: core/b.sh, tests/acc-test.sh\n- update the golden | areas: tests/golden/g.golden\n%s\n\n%sacceptance\nSPEC-1[no-code]: works\nWIRING: none\nTESTFILES:\nSPEC-1: tests/acc-test.sh\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" "$_bt" "$_bt" > "$_t"
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
_row() { jq -r --argjson i "$1" '.steps[$i] | "\(.topic)|\(.description)|\(.areas | join(","))"' "$STEPS" 2>/dev/null || echo MISSING; }

assert_eq "[T1] a code step is change" "change|guard the read in a.sh|core/a.sh" "$(_row 0)"
assert_eq "[T1] a step on the contract's test file is tests" "tests|set the flag in the test|tests/acc-test.sh" "$(_row 1)"
assert_eq "[T2] a mixed step's code part is change" "change|export the flag and check it|core/b.sh" "$(_row 2)"
assert_eq "[T2] ...and its test part a tests step, same words" "tests|export the flag and check it|tests/acc-test.sh" "$(_row 3)"
assert_eq "[T1] a test file outside the contract (a golden) is change" "change|update the golden|tests/golden/g.golden" "$(_row 4)"
assert_eq "[T2] ...five steps in all, numbered in order" "step-1 step-2 step-3 step-4 step-5" \
    "$(jq -r '[.steps[].id] | join(" ")' "$STEPS" 2>/dev/null || echo MISSING)"

# ── T3: build sees only the change steps ─────────────────────────────────────
# Build reads from a run holding just design's two outputs.
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
assert_contains "[T3] build's prompt holds the code step" "$_bp" "guard the read in a.sh"
assert_contains "[T3] ...and the code part of the mixed step" "$_bp" "export the flag and check it"
_lacks "[T3] ...and no step for the contract's tests" "$_bp" "set the flag in the test"
_scope="$(awk '/^### Scope/{f=1;next} /^### /{f=0} f' <<< "$_bp")"
assert_contains "[T5] build's scope lists the code it may touch" "$_scope" "core/a.sh"
_lacks "[T5] ...and not the design's test files" "$_scope" "tests/acc-test.sh"
assert_contains "[T5] ...a test file outside the contract stays in it" "$_scope" "tests/golden/g.golden"

# ── T4: test-author sees only the tests steps ────────────────────────────────
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    _P="$TEST_TEMP_DIR/ta-prompt.txt"
    route_to_model() {
        if [[ "$2" == *"does that establish the REQUIREMENT"* ]]; then
            printf 'SPEC-1: VERDICT: corresponds | REASON: ok\n'; return 0
        fi
        printf '%s' "$2" > "$_P"; printf 'authored\n'; return 0
    }
    resolve_tier() { printf 'T2'; }
    route_to_model_loop() { local _p; _p="$(cat "$2")"; route_to_model "$1" "$_p" >/dev/null; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; return 0; }
    TR="$TEST_TEMP_DIR/ta-repo"; mkdir -p "$TR/tests"
    printf '%s\n' 'assert_eq "[SPEC-1] placeholder" "1" "$got"' > "$TR/tests/acc-test.sh"
    ( cd "$TR" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$TR" ZBUILD_ARTIFACT_DIR="$AD" ZBUILD_STATE_DIR="$ST"
    printf '{}' > "$ST/pipeline-state.json"
    test_author_run "test-author" "$ST/pipeline-state.json" >/dev/null 2>&1
) || true
_tp="$(cat "$TEST_TEMP_DIR/ta-prompt.txt" 2>/dev/null)"
assert_contains "[T4] test-author's prompt holds the step for its test" "$_tp" "set the flag in the test"
assert_contains "[T4] ...and the test part of the mixed step" "$_tp" "export the flag and check it"
_lacks "[T4] ...and no code step" "$_tp" "guard the read in a.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
