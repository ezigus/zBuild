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

# ─── B1: metadata.artifact=plan renders input as markdown ────────────────────
plan_json='{"title":"My plan","goal":"do thing"}'
rec="$(_make_record build llm "$plan_json" "ok" '{"artifact":"plan"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
assert_contains "B1 input rendered as markdown heading" "$out" "# Plan: My plan"
assert_contains "B1 input rendered Goal field" "$out" "**Goal:** do thing"
# Original raw JSON should NOT appear verbatim in the input section.
if printf '%s' "$out" | sed -n '/── input ──/,/── output ──/p' | grep -qF '{"title"'; then
    assert_fail "B1 raw JSON not in input section" "raw JSON leaked"
else
    assert_pass "B1 raw JSON not in input section"
fi

# ─── B2: metadata.artifact=diff renders input through diff renderer ──────────
diff_text='diff --git a/x.sh b/x.sh
--- a/x.sh
+++ b/x.sh
@@ -1,1 +1,1 @@
-a
+b'
rec="$(_make_record review llm "$diff_text" "ok" '{"artifact":"diff"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
assert_contains "B2 diff heading rendered" "$out" "## a/x.sh"

# ─── B3: unknown artifact id → passthrough (no error, raw input shown) ───────
rec="$(_make_record plan llm "raw text body" "ok" '{"artifact":"nope-unknown"}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
assert_contains "B3 unknown artifact id falls through to raw" "$out" "raw text body"

# ─── B4: no metadata.artifact → existing behavior preserved (no render call) ─
rec="$(_make_record plan llm "{\"a\":1}" "ok" '{}')"
out="$(_stage_io_to_stdout "$rec" 2>/dev/null)"
# When artifact metadata absent, input is shown as-is (not via renderer).
assert_contains "B4 no metadata.artifact → raw input" "$out" '{"a":1}'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
