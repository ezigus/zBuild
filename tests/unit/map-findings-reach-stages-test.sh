#!/usr/bin/env bash
# tests/unit/map-findings-reach-stages-test.sh — every member's output of a map
# group reaches the stages that take its topic (#2480, ADR-071 §2, ADR-068 §8).
#
# Why: on #1805 run 42229975998 the six review lenses failed twice, and build's
# Previous work held none of their findings — only review-lens-security's
# summary. An output a map group writes is one file per member, so it reaches
# the input index as an array; the block listed the array's paths but read none
# of them for findings, and read the summary of the first member only. Round
# 1's critical finding (correctness) never reached build or test-author.
#
# M1 [change] build is shown a later member's code finding, labelled by its file
# M2 [change] build, which takes requirement-findings too, is shown its design finding
# M3 [change] design is shown that design finding, and no code finding: each
#             finding still goes by its topic
# M4 [change] every member's summary is shown, under its stage, not the first
#             only (the security lens's, as before, is the guard)
# M5 [change] the first member's findings are shown too: today none was, only
#             its summary
# M6 [change] stage_summaries_count counts the group when only a later member
#             wrote a summary
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every member's output of a map group reaches the stages that take it (#2480)"
setup_test_env "map-findings-reach-stages"
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

# The live template: review_lenses is a map over six lenses, security first.
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1 \
    || assert_fail "simple.yaml loads" "load_template failed"
PROOT="$REPO_ROOT/plugins"
STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_ARTIFACT_DIR="$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1

# Each lens's files written by the lens itself (#1799): its model answers with
# one finding the code must fix and one the design must.
printf 'diff --git a/a.sh b/a.sh\n+x=1\n' > "$ART/diff.patch"
printf 'scope: all\n' > "$TEST_TEMP_DIR/scope-manifest.md"
_lens() {   # <lens> <code finding words> <design finding words>
    _FINDINGS="[{\"quote\":\"x=1\",\"file\":\"a.sh\",\"category\":\"x\",\"severity\":\"high\",\"line\":1,\"message\":\"$2\",\"introduced\":true,\"fix\":\"code\"},{\"quote\":\"x=1\",\"file\":\"a.sh\",\"category\":\"x\",\"severity\":\"medium\",\"line\":1,\"message\":\"$3\",\"introduced\":true,\"fix\":\"design\"}]"
    route_to_model() { printf '%s' "{\"score\":3,\"findings\":$_FINDINGS}"; return 0; }
    _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID="$1" \
        _review_lens_run_inner "$1" "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-$1.json" "$ART" >/dev/null 2>&1 || true
}
_lens security "SEC-CODE the issue is read unchecked" "SEC-DESIGN the design omits the check"
_lens correctness "CORR-CODE resume starts one round early" "CORR-DESIGN the SPEC names the wrong iteration"
_update_stage_status "$STATE/pipeline-state.json" review_lenses complete
jq '.stage_verdicts.review_lenses = "fail"' "$STATE/pipeline-state.json" > "$STATE/s.tmp" && mv "$STATE/s.tmp" "$STATE/pipeline-state.json"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}
_pw() {   # <stage> — its Previous work, from the index the engine writes for it
    local idx; idx="$(_inputs_resolve_stage "$1" "$PROOT" "$STATE")"
    _stage_block_previous_work "$1" "$STATE" "$PROOT" "$idx" ""
}
BUILD="$(_pw build)"
DESIGN="$(_pw design)"

# ── M1 / M2 ──────────────────────────────────────────────────────────────────
print_test_section "M1/M2: build is shown every lens's findings it takes"
assert_contains "[M1] build is shown the correctness lens's code finding" "$BUILD" "CORR-CODE resume starts one round early"
assert_contains "[M1] …labelled by its file, as the open items name it" "$BUILD" "lens-correctness-code finding 1"
assert_contains "[M2] build is shown the correctness lens's design finding" "$BUILD" "CORR-DESIGN the SPEC names the wrong iteration"

# ── M3 ───────────────────────────────────────────────────────────────────────
print_test_section "M3: each finding still goes by its topic"
assert_contains "[M3] design is shown the correctness lens's design finding" "$DESIGN" "CORR-DESIGN the SPEC names the wrong iteration"
assert_not_contains "[M3] …and no code finding: design does not take code-findings" "$DESIGN" "CORR-CODE"

# ── M4 ───────────────────────────────────────────────────────────────────────
print_test_section "M4: every member's summary"
assert_contains "[M4] the correctness lens's summary is shown" "$BUILD" "review-lens-correctness"
assert_contains "[M4] …and the security lens's, as before" "$BUILD" "review-lens-security"

# ── M5 ───────────────────────────────────────────────────────────────────────
print_test_section "M5: the first member too"
assert_contains "[M5] build is shown the security lens's code finding as a finding" "$BUILD" \
    "lens-security-code finding 1 (opened by review_lenses): security lens, high: SEC-CODE the issue is read unchecked"

# ── M6 ───────────────────────────────────────────────────────────────────────
print_test_section "M6: the summary count"
rm -f "$ART/lens-security-summary.md"
assert_contains "[M6] the group counts when only a later lens wrote a summary" \
    "$(_summaries_collect "$STATE/pipeline-state.json" "$PROOT")" "review_lenses|fail|"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
