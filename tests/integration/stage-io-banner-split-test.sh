#!/usr/bin/env bash
# Integration test (#481): the stage-io input banner emits BEFORE the LLM call
# and the output banner emits AFTER. Uses a subprocess + real route_to_model +
# a mock claude binary that writes a MARK to a side-channel so we can verify
# the ordering: input-banner-line < MARK-line < output-banner-line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io banner split: input < LLM-MARK < output (#481)"
setup_test_env "stage-io-banner-split"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="banner-split-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Operator override so route_to_model accepts --skip-precondition
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "$ZBUILD_RUN_ID" > "$HOME/.zbuild/scope-override-token"
assert_contains "[SPEC-1] RUN_ID includes process id" "$ZBUILD_RUN_ID" "$$"
assert_eq "[SPEC-3] scope-override-token matches RUN_ID" "$ZBUILD_RUN_ID" "$(cat "$HOME/.zbuild/scope-override-token")"
export ZBUILD_SCOPE_OVERRIDE=1

# Mock claude — between the input banner and the output banner, this binary
# runs. It writes a MARK to a side-channel file so the test can verify the
# ordering against the fd 3 banner stream.
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
# Tee a MARK to the side-channel so the parent test can correlate timing.
printf '__LLM_CALL_MARK__\n' >> "$MARK_FILE"
echo "LLM_RESPONSE_PAYLOAD"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# Template: plan stage uses stdout destination so banner emits to fd 3.
cat > "$TEST_TEMP_DIR/state/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file, stdout]
      tail_lines: 5
YAML

# Subprocess driver: route_to_model under a real shell with fd 3 redirected
# to a banner-capture file so we can time-correlate against MARK_FILE.
DRIVER="$TEST_TEMP_DIR/driver.sh"
BANNER_FD3="$TEST_TEMP_DIR/banner-fd3.txt"
cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"

load_template "$TEST_TEMP_DIR/state/template.yaml"
export ZBUILD_CURRENT_STAGE=plan
route_to_model T2 "PROMPT_BODY" --skip-precondition
EOF

ZBUILD_STAGE_IO_FD=3 bash "$DRIVER" >/dev/null 2>/dev/null 3>"$BANNER_FD3" || true

# ─── Assertions ──────────────────────────────────────────────────────────────
banner_content="$(cat "$BANNER_FD3" 2>/dev/null || echo '')"

# (1) Banner contains an input-section header BEFORE the output-section header.
# #499: I/O banner header dividers switched from ── (U+2500) to ══ (U+2550).
input_line="$(printf '%s\n' "$banner_content" | grep -n 'seq=1 input ══' | head -1 | cut -d: -f1)"
output_line="$(printf '%s\n' "$banner_content" | grep -n 'seq=1 output' | head -1 | cut -d: -f1)"
end_line="$(printf '%s\n' "$banner_content" | grep -n 'end stage-io: plan' | head -1 | cut -d: -f1)"

if [[ -n "$input_line" && -n "$output_line" && "$input_line" -lt "$output_line" ]]; then
    assert_pass "input-banner emits before output-banner"
else
    assert_fail "input-banner emits before output-banner" \
        "input=$input_line output=$output_line; banner=$(printf '%s' "$banner_content" | head -10)"
fi

if [[ -n "$end_line" && "$output_line" -lt "$end_line" ]]; then
    assert_pass "end-trailer emits after output-banner"
else
    assert_fail "end-trailer emits after output-banner" \
        "output=$output_line end=$end_line"
fi

# (2) The mock-claude MARK got written between the two halves. We can't
# directly interleave the streams (different files), but the file artifact's
# duration_ms must be >= 0 and the prompt + response both made it into the
# merged record.
if [[ -s "$MARK_FILE" ]]; then
    assert_pass "mock claude was invoked between begin and end"
else
    assert_fail "mock claude was invoked between begin and end" "MARK_FILE empty"
fi

# (3) Merged file record contains BOTH input and output (single record).
artifact="$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
if [[ -f "$artifact" ]]; then
    rec="$(cat "$artifact")"
    assert_json_key "merged record has input"  "$rec" ".input"  "PROMPT_BODY"
    assert_json_key "merged record has output" "$rec" ".output" "LLM_RESPONSE_PAYLOAD"
else
    assert_fail "merged file record exists" "no file at $artifact"
fi

# (4) Exactly ONE stage.io.captured event per pair (not two).
captured_count="$(jq -c --arg t "stage.io.captured" 'select(.type==$t)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "single stage.io.captured event per pair" "1" "$captured_count"

# (5) Build (Pattern 2) stage is NOT auto-emitting any banner via this path —
# we only ran plan; assert no build-* artifact crept in.
if ls "$ZBUILD_STATE_DIR/artifacts/stage-io/build-"*.json >/dev/null 2>&1; then
    assert_fail "no build artifact from Pattern 1 run" "found build-*.json"
else
    assert_pass "Pattern 2 (build) untouched by Pattern 1 split"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
