#!/usr/bin/env bash
# tests/unit/no-line-numbers-test.sh — no line number is passed on from one
# stage to the next (#2506, ADR-067 §8, ADR-072 §3, ADR-069 §2).
#
# Why: on #1805 run 42556446368 every stage passed line numbers on, and lines
# move as the change is made. A lens was asked for a line and a quote, and the
# finding shown to the stages that fix it kept `file:line` and dropped the
# quote; design's decisions and findings cited lines such as `runner.sh:3442`
# as verified facts. #2462 removed line numbers only from a [done] SPEC's
# evidence.
#
# L1 [change] the rules every stage gets, building or judging, say: never name
#             a line number — name the file and the function, or quote the text
# L2 [change] a lens is not asked for a line (review-lens and security-lens)
# L3 [change] a lens finding shown under Previous work carries its quote and no
#             line
# L4 [change] design's check refuses `file:123` in a decision or a finding, and
#             says what to write instead
# L5 [guard]  a quote (`file:"text"`) is no line number; a [done] evidence line
#             number is still reported once, as before
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "no line number is passed on (#2506)"
setup_test_env "no-line-numbers"
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
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}
_RULE="never name a line number: lines move as the code changes. Name the file and the function, or quote the text."

# ── L1 ───────────────────────────────────────────────────────────────────────
print_test_section "L1: the rule every stage gets"
PR="$TEST_TEMP_DIR/plugins"; S="$TEST_TEMP_DIR/rstate"; mkdir -p "$PR/agent/w" "$PR/agent/j" "$S/artifacts"
printf 'id: w\nkind: agent\n' > "$PR/agent/w/manifest.yaml"
printf 'id: j\nkind: agent\ntools: read\n' > "$PR/agent/j/manifest.yaml"
_full="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules w "$S" "$PR/agent/w/manifest.yaml" 2>/dev/null)")"
_fresh="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules w "$S" "$PR/agent/w/manifest.yaml" fresh 2>/dev/null)")"
_judge="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules j "$S" "$PR/agent/j/manifest.yaml" 2>/dev/null)")"
assert_contains "[L1] a building call is told never to name a line number" "$_full" "$_RULE"
assert_contains "[L1] ...and so is a judging call" "$_fresh" "$_RULE"
assert_contains "[L1] ...and a stage whose every call judges" "$_judge" "$_RULE"

# ── L2 ───────────────────────────────────────────────────────────────────────
print_test_section "L2: a lens is not asked for a line"
_lp="$(_rl_build_lens_prompt correctness "diff --git a/a.sh b/a.sh" "")"
assert_not_contains "[L2] the review lens's report has no line field" "$_lp" '"line"'
assert_contains "[L2] ...and still asks for a quote" "$_lp" '"quote"'
_sp="$(cat "$REPO_ROOT/plugins/agent/security-lens/prompts/security.md")"
assert_not_contains "[L2] the security lens is not asked for file:line" "$_sp" "file:line"

# ── L3 ───────────────────────────────────────────────────────────────────────
print_test_section "L3: a lens finding is shown with its quote, not a line"
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1 \
    || assert_fail "simple.yaml loads" "load_template failed"
PROOT="$REPO_ROOT/plugins"
STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_ARTIFACT_DIR="$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
printf 'diff --git a/a.sh b/a.sh\n+x=1\n' > "$ART/diff.patch"
printf 'scope: all\n' > "$TEST_TEMP_DIR/scope-manifest.md"
# A model that still sends a line: the line is not passed on.
route_to_model() {
    printf '%s' '{"score":3,"findings":[{"quote":"x=1","file":"a.sh","category":"x","severity":"high","line":4242,"message":"LINE-FINDING the read is unchecked","introduced":true,"fix":"code"}]}'
}
_TPL_STAGE_FAIL_ON_review_lenses="medium high critical" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=correctness \
    _review_lens_run_inner correctness "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-correctness.json" "$ART" >/dev/null 2>&1 || true
_update_stage_status "$STATE/pipeline-state.json" review_lenses complete
_idx="$(_inputs_resolve_stage build "$PROOT" "$STATE")"
_bpw="$(_stage_block_previous_work build "$STATE" "$PROOT" "$_idx" "")"
assert_contains "[L3] build is shown the lens finding" "$_bpw" "LINE-FINDING the read is unchecked"
assert_contains "[L3] ...with its file and quote" "$_bpw" 'LINE-FINDING the read is unchecked (a.sh: "x=1"; fix: code)'
assert_not_contains "[L3] ...and no line" "$_bpw" "4242"

# ── L4 / L5 ──────────────────────────────────────────────────────────────────
print_test_section "L4/L5: design's check refuses a line number anywhere"
ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ROOT/tests" "$ROOT/scripts"
printf 'assert "[DSWORK-1] ok" 1 1\n' > "$ROOT/tests/a-test.sh"
printf 'line one\nline two\nline three\n' > "$ROOT/scripts/wire.sh"
_md() {   # <text in the design, before its blocks> [acceptance SPEC line]
    printf '# Design\n\n%s\n\n```scope\nscripts/wire.sh\n```\n\n```acceptance\n' "$1"
    printf '%s\n' "${2:-DSWORK-1[code]: it works}" '  When: it runs' '  Then: it is done'
    printf 'WIRING: scripts/wire.sh\nTESTFILES:\nDSWORK-1: tests/a-test.sh\n```\n'
}
_check() {   # <design.md content> — sets V (violations) and FB (what design reads)
    local d="$TEST_TEMP_DIR/design-$RANDOM.md" v
    printf '%s' "$1" > "$d"
    _design_checks "$d" "$ROOT" ""
    V="${_DESIGN_VIOLATIONS[*]-}"
    FB=""; for v in "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}"; do FB+="$(_dck_plain "$v")"$'\n'; done
}
_check "$(_md '## Decision
Read the guard at scripts/wire.sh:3 and keep it.')"
assert_contains "[L4] a line number in a decision is refused" "$V" "LINE_NUMBER scripts/wire.sh:3"
assert_contains "[L4] ...saying to name the function or quote the text" "$FB" \
    "names a line number (scripts/wire.sh:3), and line numbers move as the change is made — name the file and the function, or quote the text: scripts/x.sh:\"run_guard()\""
_check "$(_md '## Findings
- design finding 2: done — verified at core/runner.sh:3442-3450')"
assert_contains "[L4] ...and so is one in a finding" "$V" "LINE_NUMBER core/runner.sh:3442"
_check "$(_md '## Decision
Keep scripts/wire.sh:"line two" as it is.')"
assert_eq "[L5] a quote is no line number" "" "$V"
_check "$(_md '## Decision
Keep it.' 'DSWORK-1[done]: it works evidence: scripts/wire.sh:2')"
assert_contains "[L5] a [done] evidence line number is reported as before" "$V" "DONE_LINE_EVIDENCE DSWORK-1 scripts/wire.sh:2"
assert_not_contains "[L5] ...and not twice" "$V" "LINE_NUMBER scripts/wire.sh:2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
