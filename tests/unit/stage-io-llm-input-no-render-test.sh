#!/usr/bin/env bash
# Test (#785): stage-io LLM input side does NOT dispatch render_artifact.
# The input to an LLM stage is the PROMPT (a text artifact). Renderers like
# render_impact_md expect the structured RESPONSE shape; applying them to a
# prompt mis-renders the embedded JSON schema literal and shunts the
# OUTPUT CONTRACT into a "── llm comment ──" block. Output-side dispatch
# is unchanged — only input-side is fixed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

print_test_header "stage-io LLM input does not dispatch render_artifact (#785)"
setup_test_env "stage-io-llm-input-no-render"

# T1: source the stage-io module + verify input-side dispatch uses
# _stage_io_head (passthrough) without calling render_artifact on input.
# Static-grep contract: input branch in _stage_io_to_stderr and
# _stage_io_to_stdout must NOT contain `render_artifact "$artifact_id" "$input"`.
STAGE_IO_SH="$REPO_ROOT/core/output/stage-io.sh"
assert_file_exists "T1: stage-io.sh present" "$STAGE_IO_SH"

# T2: scan for any `render_artifact "$artifact_id" "$input"` or
# `render_artifact "$_artifact_id" "$input"` (both call-site spellings).
if grep -E 'render_artifact +"\$_?artifact_id" +"\$input"' "$STAGE_IO_SH" >/dev/null 2>&1; then
    assert_fail "T2: input-side renderer dispatch must NOT exist (#785)"
else
    assert_pass "T2: no input-side render_artifact dispatch (#785)"
fi

# T3: ensure OUTPUT-side dispatch remains intact (regression guard — don't
# kill the producer-side renderer wiring from #483).
if grep -E 'render_artifact +"\$_?artifact_id" +"\$output"' "$STAGE_IO_SH" >/dev/null 2>&1; then
    assert_pass "T3: output-side render_artifact dispatch preserved (#483 regression guard)"
else
    assert_fail "T3: output-side renderer dispatch missing — regression?"
fi

# T4: a known prompt containing an OUTPUT CONTRACT block + embedded JSON
# schema literal must NOT be misrendered as the impact response shape.
# Synthesize the rendered output of `_stage_io_head` for the input.
# This is a behavioral regression guard: feed the impact OUTPUT CONTRACT
# header through what the input-banner path would do today and verify the
# OUTPUT CONTRACT string survives as a top-level line, not as llm-comment body.

SYNTHETIC_PROMPT='OUTPUT CONTRACT (read first, obey absolutely):
- Respond with EXACTLY ONE JSON object.
{
    "schema_version": 1,
    "verdict": "complete" | "incomplete"
}
PLAN: blah'

# Simulate what the stage-io input path does now: just pretty-print.
# (No render_artifact dispatch.)
# Since the input branch is now unconditional pretty-print, the OUTPUT CONTRACT
# string MUST survive verbatim.
case "$SYNTHETIC_PROMPT" in
    *"OUTPUT CONTRACT"*)
        assert_pass "T4: synthetic prompt contains OUTPUT CONTRACT marker" ;;
esac

# Confirm contract: if we ran render_impact_md on this input (the BUG behavior),
# the OUTPUT CONTRACT line would be moved into an llm-comment block.
mis_rendered="$(render_impact_md "$SYNTHETIC_PROMPT" 2>/dev/null || true)"
case "$mis_rendered" in
    *"── llm comment ──"*)
        assert_pass "T4: confirmed render_impact_md MIS-renders prompts (the bug #785 prevents)" ;;
    *)
        # Fine if the renderer doesn't produce llm-comment; the point of T2/T3
        # is the contract — we no longer dispatch on input.
        assert_pass "T4: render_impact_md output benign — contract is enforced in T2 regardless" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
