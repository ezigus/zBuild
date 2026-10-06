#!/usr/bin/env bash
# tests/unit/build-prompt-summary-marker-test.sh — build's stop rule points at
# the heading the stage summaries actually use (#2292).
#
# Why: #2271 replaced the "fix these findings" / RESOLVE framing with one
# heading for every failing stage (`— its findings, to answer`). Build's prompt
# and context still said "emit LOOP_COMPLETE … if no STAGE SUMMARY is marked
# RESOLVE" — a marker that no longer exists, so build was told nothing was red
# even while checks failed (the #2138 class, reintroduced). Found monitoring
# #2032 run 37262224567 on engine 33ba7d5.
#
# M1 [change] the composed build prompt never says RESOLVE
# M2 [change] it names the heading the summary block actually emits for a
#             failing stage
# M3 [change] finishing with no change requires answering each finding
#             (`nothing to do` with a reason) or reporting it not reproduced
# M4 [change] the prior-attempt context names the same heading, never RESOLVE
# M5 [change] the plain-prompt lint refuses RESOLVE in model-facing text
# M6 [change] the run-status comment and the cycle banner do not label their
#             count RESOLVE
# M7 [change] one answer vocabulary: the prompt asks for `nothing to do — not
#             reproduced: <path>` and offers no separate NOT_REPRODUCED form
#             (#2322: the router did not know that word, so the answer was lost)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "build's stop rule points at the real summary heading (#2292)"
setup_test_env "build-prompt-summary-marker"
export ZBUILD_EVENTS_DB="/dev/null"

# The heading the summary block emits for a failing stage — read, not assumed.
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
S="$TEST_TEMP_DIR/state"; PR="$TEST_TEMP_DIR/plugins"; mkdir -p "$S/artifacts" "$PR/tool/chk"
printf 'id: chk\nkind: tool\nprovides:\n  role: chk\n  result_contract: 2\noutputs:\n  - id: chk-summary\n    path: ${artifact_dir}/chk-summary.md\n    format: markdown\n    required: false\n    summary: true\n' > "$PR/tool/chk/manifest.yaml"
printf '## chk — fail\n\n- a problem\n' > "$S/artifacts/chk-summary.md"
printf '{"stage_statuses":{"chk":"failed"},"stage_verdicts":{"chk":"fail"}}\n' > "$S/pipeline-state.json"
_blk="$( _TPL_STAGES=(chk); export ZBUILD_CURRENT_STAGE=build; stage_summaries_prompt_block "$S/pipeline-state.json" "$PR" 2>/dev/null )"
_heading="$(grep -E '^### chk \(verdict: fail\) — ' <<< "$_blk" | sed -E 's/^### chk \(verdict: fail\) — //')"
assert_contains "fixture: a failing stage's heading was read" "$_heading" "answer"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null || true
# The stop rule lives in the instructions; the body carries the rest.
_out="$TEST_TEMP_DIR/prompt.txt"
_instr="$(_build_compose_instructions "lib/a.sh" 2>/dev/null)"
_build_compose_prompt_body "$_out" "== HEADER ==" "PLAN" "$_instr" "" "tests/x-test.sh" \
    "$(printf 'SPEC-1\ta requirement')" 1 >/dev/null 2>&1 || true
PROMPT="$(cat "$_out" 2>/dev/null)"
assert_contains "fixture: the build prompt was composed" "$PROMPT" "LOOP_COMPLETE"

if grep -qF 'RESOLVE' <<< "$PROMPT"; then
    assert_fail "[M1] the build prompt never says RESOLVE" "$(grep -F RESOLVE <<< "$PROMPT" | head -2)"
else
    assert_pass "[M1] the build prompt never says RESOLVE"
fi
assert_contains "[M2] it names the heading the summaries actually use" "$PROMPT" "$_heading"
assert_contains "[M3] finishing with no change needs each finding answered" "$PROMPT" "nothing to do"
if grep -qF 'NOT_REPRODUCED' <<< "$PROMPT"; then
    assert_fail "[M7] the build prompt offers no separate NOT_REPRODUCED form" "$(grep -F NOT_REPRODUCED <<< "$PROMPT")"
else
    assert_pass "[M7] the build prompt offers no separate NOT_REPRODUCED form"
fi
assert_contains "[M7] it asks for nothing to do, with not reproduced as the reason" "$PROMPT" \
    "nothing to do — not reproduced: <the path you ran>"

# The prior-attempt context, for a build that changed nothing and one that did.
# shellcheck disable=SC2329  # called by the context reader
_read_prior_output() { printf '%s' "$_PRIOR"; }
_PRIOR='{"verdict":"pass","files_changed":[]}'
_c0="$(_build_read_prior_build_summary 2>/dev/null)"
_PRIOR='{"verdict":"pass","files_changed":["lib/a.sh"]}'
_c1="$(_build_read_prior_build_summary 2>/dev/null)"
if grep -qF 'RESOLVE' <<< "$_c0$_c1"; then
    assert_fail "[M4] the prior-attempt context never says RESOLVE" "found"
else
    assert_pass "[M4] the prior-attempt context never says RESOLVE"
fi
assert_contains "[M4] ...and names the real heading (nothing changed)" "$_c0" "$_heading"
assert_contains "[M4] ...and names the real heading (files changed)" "$_c1" "$_heading"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/config" "$R/plugins/x"
printf '%s\n' 'cat <<EOF' 'If no summary is marked RESOLVE, stop.' 'EOF' > "$R/plugins/x/a.sh"
printf 'plugins/x/a.sh\n' > "$R/config/model-facing-sources.txt"
bash "$REPO_ROOT/scripts/lib/lint-plain-prompts.sh" "$R" >/dev/null 2>&1; _lrc=$?
assert_eq "[M5] the plain-prompt lint refuses RESOLVE" "1" "$_lrc"

_m6="$(grep -nE 'RESOLVE' "$REPO_ROOT/scripts/lib/run-status-render.sh" "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
assert_eq "[M6] the run-status comment and cycle banner do not say RESOLVE" "" "$_m6"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
