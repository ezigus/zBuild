#!/usr/bin/env bash
# plugins/agent/build/tests/build-step-parts-test.sh — a design step may have
# numbered parts, 1.1, 1.2 …, one file each; build answers each part with one
# quote, and a step is done when all its parts are (#2586 R5; ADR-073,
# ADR-072 §3).
#
# Why: on #2532 run 45017980554 a step spanned three files. Build's answer
# reader split a quote at its first " | ", so three `file | line` pairs read as
# one quote; when build gave one file, the whole step was accepted on it.
#
# SP1 [change] design's writer keeps each part's number: step-1.1, step-1.2,
#              step-2 in design-steps.json
# SP2 [change] design's check flags a step or a part that names more than one
#              file, naming it; a part with one file passes
# SP3 [change] design's prompt asks for numbered parts, one file each
# SP4 [change] build answers `step 1.2: done — <file> | <line>`: read as part
#              1.2's answer; the judge is shown `step 1.2` and its `1.2: does`
#              is read
# SP5 [change] a part with no answer is a finding naming the part (step 1.1),
#              so the step is not done
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a step's numbered parts, one file each (#2586 R5)"
setup_test_env "plugin-build-step-parts"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_RUN_ID="build-step-parts-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# ── The design, by design's own writer ───────────────────────────────────────
DESIGN_MD="$TEST_TEMP_DIR/design.md"; STEPS="$TEST_TEMP_DIR/design-steps.json"
printf '%s\n' '# Claim' '' '## Decision' 'One label.' '' '```steps' \
    '- 1.1 make claim_take add the label | areas: lib/claim.sh | serves: DSCLM-1' \
    '- 1.2 describe the label in the README | areas: README.md | serves: DSCLM-1' \
    '- check the label on release | areas: lib/release.sh | serves: DSCLM-1' \
    '```' '' '```acceptance' 'DSCLM-1[code]: claim_take labels the issue' '  When: an issue is claimed' \
    '  Then: it has the label' 'WIRING: none' '```' > "$DESIGN_MD"
(
    # shellcheck source=../../../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _design_write_steps "$DESIGN_MD" "$STEPS"
)
print_test_section "SP1-SP3: design"
assert_eq "[SP1] each part keeps its number" "step-1.1 step-1.2 step-2" "$(jq -r '[.steps[].id] | join(" ")' "$STEPS" 2>/dev/null)"

CR="$TEST_TEMP_DIR/check-repo"; mkdir -p "$CR/lib"
( cd "$CR" && git init -q && git config user.email t@t && git config user.name t \
    && echo 'a() { :; }' > lib/a.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
MANY="$TEST_TEMP_DIR/many.md"
printf '%s\n' '# D' '' '## Decision' 'x' '' '```steps' \
    '- guard both reads | areas: lib/a.sh, lib/b.sh | serves: DSWORK-1' \
    '- 2.1 guard the first read | areas: lib/a.sh | serves: DSWORK-1' \
    '```' '' '```acceptance' 'DSWORK-1[no-code]: works' 'WIRING: none' '```' > "$MANY"
_v="$(
    # shellcheck source=../../../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _design_checks "$MANY" "$CR" "" >/dev/null 2>&1
    for x in "${_DESIGN_VIOLATIONS[@]}"; do [[ "$x" == STEP_MANY_FILES* ]] && printf '%s\n' "$x"; done
)"
assert_contains "[SP2] a step over two files is flagged, naming it" "$_v" "STEP_MANY_FILES guard both reads"
_lacks "[SP2] ...a part with one file is not" "$_v" "guard the first read"
_dp="$(
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2"; return 0; }
    apply_scope_redaction() { cp "$1" "$2"; return 0; }
    D="$TEST_TEMP_DIR/run"; mkdir -p "$D/state/artifacts"; git -C "$D" init -q >/dev/null 2>&1
    printf 'scope: all\n' > "$D/state/scope-manifest.md"
    _P="$TEST_TEMP_DIR/dprompt"; route_to_model() { [[ -s "$_P" ]] || printf '%s' "$2" > "$_P"; return 0; }
    ZBUILD_REPO_ROOT="$D" _design_stage_run_inner "$D/state/scope-manifest.md" "$D/state/artifacts/design.md" "$D/state/artifacts" >/dev/null 2>&1
    tr -s '[:space:]' ' ' < "$_P"
)"
assert_contains "[SP3] design's prompt asks for numbered parts, one file each" "$_dp" \
    "A step over more than one file is split into numbered parts, 1.1, 1.2, each naming one file"

# ── Build ────────────────────────────────────────────────────────────────────
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/lib"
CLAIM_LINE='    gh issue edit "$1" --add-label zbuild:claimed'
README_LINE='The claim label is zbuild:claimed.'
REL_LINE='    gh issue edit "$1" --remove-label zbuild:claimed'
(
    cd "$R" && git init -q -b main && git config user.email t@zbuild && git config user.name t
    printf '%s\n' 'claim_take() {' '    :' '}' > lib/claim.sh; printf '# zbuild\n' > README.md
    printf '%s\n' 'release() {' '    :' '}' > lib/release.sh
    git add -A && git commit -q -m base && git checkout -q -b zbuild/issue-2586
    printf '%s\n' 'claim_take() {' "$CLAIM_LINE" '}' > lib/claim.sh
    printf '%s\n' '# zbuild' "$README_LINE" > README.md
    printf '%s\n' 'release() {' "$REL_LINE" '}' > lib/release.sh
    git add -A && git commit -q -m "claim label"
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$R"
# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; }
_route_loop_close_final_banner() { return 0; }
MOCK_LOOP_RESPONSE=""
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=1; _ROUTE_LOOP_OUTPUT_TOKENS=1; _ROUTE_LOOP_LAST_RESPONSE="$MOCK_LOOP_RESPONSE"
    return 0
}
JPROMPT="$TEST_TEMP_DIR/judge-prompt"; JUDGE_REPLY=""
route_to_model() { printf '%s' "$2" > "$JPROMPT"; printf '%s\n' "$JUDGE_REPLY"; }
_run() {
    AD="$TEST_TEMP_DIR/$1"; rm -rf "$AD"; mkdir -p "$AD"; cp "$STEPS" "$AD/design-steps.json"
    MOCK_LOOP_RESPONSE="$2"; rm -f "$JPROMPT"
    _build_stage_run_inner "" "$AD/design-steps.json" "$AD/diff.patch" "$AD/build-summary.json" "$AD" >"$AD/log" 2>&1 || true
}
_findings() { jq -r '[.data.findings[]?.text] | join("\n")' "$AD/build-summary.json" 2>/dev/null; }

print_test_section "SP4-SP5: build answers each part"
JUDGE_REPLY=$'1.1: does\n1.2: does\n2: does'
_run all "step 1.1: done — lib/claim.sh | $CLAIM_LINE"$'\n'"step 1.2: done — README.md | $README_LINE"$'\n'"step 2: done — lib/release.sh | $REL_LINE"
_jp="$(cat "$JPROMPT" 2>/dev/null)"
assert_contains "[SP4] the judge is shown part 1.2 by its number" "$_jp" "### step 1.2"
assert_eq "[SP4] every part answered and judged: the try passes" "pass" "$(jq -r '.outcome // "none"' "$AD/build-summary.json" 2>/dev/null)"
assert_eq "[SP4] ...no finding" "" "$(_findings)"
JUDGE_REPLY=$'1.2: does\n2: does'
_run missing "step 1.2: done — README.md | $README_LINE"$'\n'"step 2: done — lib/release.sh | $REL_LINE"
_f="$(_findings)"
assert_contains "[SP5] a part with no answer is a finding naming it" "$_f" "step 1.1 has no answer"
_lacks "[SP5] ...not part 1.2, which was answered" "$_f" "step 1.2 has no answer"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
