#!/usr/bin/env bash
# tests/unit/design-writes-steps-test.sh — the plan stage is gone; design writes
# the ordered work steps (#2445, ADR-013, ADR-070).
#
# Why: plan and design both listed the files to change, and design's scope was
# the one enforced; what plan added was an ordered list of work items. Design
# now writes that list itself, in a ```steps block, and design turns it into the
# work-steps file every reader already finds by what it contains (a `steps`
# list — earlier_work_plan), so build and pr-open read it unchanged.
#
# S1 [change] design's prompt asks for a ```steps block: the ordered work
#             items, each with the files it touches; it shows no plan
# S2 [change] a design that passes has its steps written to design-steps.json,
#             found as the work plan (earlier_work_plan)
# S3 [change] design runs with no plan.json anywhere
# S4 [change] the plan stage is gone: no template runs it, and its plugin is
#             removed
# S5 [change] build runs with no work-steps file (a design with none)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design writes the work steps; plan is gone (#2445)"
setup_test_env "design-writes-steps"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
# shellcheck source=../../scripts/lib/earlier-output.sh
source "$REPO_ROOT/scripts/lib/earlier-output.sh"

route_to_model() {
    local _bt='```' _t; _t="$(zb_test_prompt_write_path "$2")"
    if [[ -n "$_t" ]]; then
        cp "$2" "$TEST_TEMP_DIR/design-prompt.txt" 2>/dev/null || printf '%s' "$2" > "$TEST_TEMP_DIR/design-prompt.txt"
        mkdir -p "$(dirname "$_t")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\nfoo.sh\nbar.sh\n%s\n\n%ssteps\n- add the flag to foo.sh | areas: foo.sh\n- refuse a missing config | areas: foo.sh, bar.sh\n%s\n\n%sacceptance\nSPEC-1[no-code]: works\nWIRING: none\nTESTFILES:\n%s\n' \
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

# ── S3 / S1 / S2 ─────────────────────────────────────────────────────────────
set +e
_design_stage_run_inner "$ST/scope-manifest.md" "$AD/design.md" "$AD" >/dev/null 2>&1
_rc=$?
assert_eq "[S3] design runs with no plan.json" "0" "$_rc"
assert_eq "[S3] ...and passes" "pass" "$(jq -r '.outcome // "MISSING"' "$AD/design-verdict.json" 2>/dev/null)"
_p="$(cat "$TEST_TEMP_DIR/design-prompt.txt" 2>/dev/null)"
assert_contains "[S1] the prompt asks for a steps block" "$_p" '```steps'
assert_contains "[S1] ...each work item with the files it touches" "$_p" "| areas:"
if grep -qE '^### Plan$|plan\.files' <<< "$_p"; then
    assert_fail "[S1] the prompt shows no plan" "it names a plan"
else
    assert_pass "[S1] the prompt shows no plan"
fi
_steps="$AD/design-steps.json"
assert_eq "[S2] the steps are written, in order" "add the flag to foo.sh|refuse a missing config" \
    "$(jq -r '[.steps[].description] | join("|")' "$_steps" 2>/dev/null || echo MISSING)"
assert_eq "[S2] ...each with its files" "foo.sh,bar.sh" "$(jq -r '.steps[1].areas | join(",")' "$_steps" 2>/dev/null || echo MISSING)"
assert_eq "[S2] ...numbered step-1, step-2" "step-1 step-2" "$(jq -r '[.steps[].id] | join(" ")' "$_steps" 2>/dev/null || echo MISSING)"
assert_eq "[S2] readers find them as the work plan" "$_steps" "$(earlier_work_plan "$AD" "$ST" 2>/dev/null)"

# ── S4 ───────────────────────────────────────────────────────────────────────
assert_eq "[S4] the plan plugin is removed" "absent" "$([[ -d "$REPO_ROOT/plugins/agent/plan" ]] && echo present || echo absent)"
for _t in "$REPO_ROOT"/config/templates/*.yaml; do
    if grep -qE '^  - plan$|^plan:' "$_t"; then
        assert_fail "[S4] $(basename "$_t") runs no plan stage" "it still names plan"
    else
        assert_pass "[S4] $(basename "$_t") runs no plan stage"
    fi
done

# ── S5 ───────────────────────────────────────────────────────────────────────
if grep -q 'missing_plan_json' "$REPO_ROOT/plugins/agent/build/plugin.sh"; then
    assert_fail "[S5] build no longer refuses to run without a work-steps file" "build/plugin.sh still has missing_plan_json"
else
    assert_pass "[S5] build no longer refuses to run without a work-steps file"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
