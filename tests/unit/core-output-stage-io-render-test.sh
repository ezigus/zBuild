#!/usr/bin/env bash
# Tests: stage-io banner — metadata.artifact dispatches through renderer (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io banner renderer dispatch (#470)"
setup_test_env "stage-io-render"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-run-render"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"

# Stub templates so renderer paths are exercised.
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact() { printf ''; }

# Helper: build a record with optional metadata
_make_record() {
    local stage="$1" kind="$2" input="$3" output="$4" metadata_json="${5:-{\}}"
    jq -n \
        --arg stage "$stage" --arg kind "$kind" \
        --arg input "$input" --arg output "$output" \
        --argjson metadata "$metadata_json" \
        '{
            schema_version: 1, run_id: "t470", stage: $stage, kind: $kind, seq: 1,
            input: $input, output: $output, exit_code: null, duration_ms: 100,
            metadata: $metadata, ts: "2026-05-29T00:00:00Z"
        }'
}

# ─── B1 (#785): metadata.artifact=plan does NOT render input ────────────────
# The input to an LLM stage is the PROMPT (a text artifact), not the
# structured response shape render_plan_md expects. Dispatching on input
# mis-rendered the prompt's embedded schema literal. Pre-#785 this test
# pinned that broken behavior; now it pins the corrected passthrough.
plan_json='{"title":"My plan","goal":"do thing"}'
rec="$(_make_record build llm "$plan_json" "ok" '{"artifact":"plan"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
# Input section now shows the prompt verbatim (no render_plan_md dispatch).
if grep -qF '{"title":"My plan"' <<< "$(printf '%s' "$out" | sed -n '/── input ──/,/── output ──/p')"; then
    assert_pass "B1 (#785) input shows raw prompt (no render dispatch)"
else
    assert_fail "B1 (#785) input should show raw prompt verbatim" "got: $out"
fi

# ─── B2 (#785): metadata.artifact=diff also passthrough on input side ───────
diff_text='diff --git a/x.sh b/x.sh
--- a/x.sh
+++ b/x.sh
@@ -1,1 +1,1 @@
-a
+b'
rec="$(_make_record review llm "$diff_text" "ok" '{"artifact":"diff"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
# Input section shows the raw diff text (no render_diff_md dispatch).
assert_contains "B2 (#785) input shows raw diff verbatim" "$out" "diff --git a/x.sh"

# ─── B3: unknown artifact id → passthrough (no error, raw input shown) ───────
rec="$(_make_record plan llm "raw text body" "ok" '{"artifact":"nope-unknown"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
assert_contains "B3 unknown artifact id falls through to raw" "$out" "raw text body"

# ─── B4: no metadata.artifact → existing behavior preserved (no render call) ─
rec="$(_make_record plan llm "{\"a\":1}" "ok" '{}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
# When artifact metadata absent, input is shown as-is (not via renderer).
assert_contains "B4 no metadata.artifact → raw input" "$out" '{"a":1}'

# ─── B5 (#483): metadata.artifact also dispatches the OUTPUT side ────────────
# The #470 wave only handled input. Producer-side tagging (#483) needs the
# output branch to render too, otherwise plan/review's own banner shows raw
# JSON. Lock the new dispatch in the same shape as B1.
plan_output_json='{"title":"Out plan","goal":"render output"}'
rec="$(_make_record build llm "in" "$plan_output_json" '{"artifact":"plan"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
assert_contains "B5 output rendered as markdown heading" "$out" "# Plan: Out plan"
assert_contains "B5 output rendered Goal field" "$out" "**Goal:** render output"
# Original raw JSON should NOT appear verbatim in the output section.
if grep -qF '{"title":"Out plan"' <<< "$(printf '%s' "$out" | sed -n '/── output ──/,/── end stage-io/p')"; then
    assert_fail "B5 raw JSON not in output section" "raw JSON leaked"
else
    assert_pass "B5 raw JSON not in output section"
fi

# ─── B6 (#483): unknown artifact id on OUTPUT → passthrough (no error) ───────
rec="$(_make_record plan llm "in" "raw output body" '{"artifact":"nope-unknown"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
assert_contains "B6 unknown artifact id falls through on output" "$out" "raw output body"

# ─── B7 (#483): no metadata.artifact → output uses pretty-print path ─────────
rec="$(_make_record plan llm "in" '{"a":1}' '{}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
# When artifact metadata absent, output still renders (raw or pretty); JSON
# stays present. This locks the negative half of B5: no-tag → no render call.
assert_contains "B7 no metadata.artifact → output unchanged content" "$out" '"a": 1'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
