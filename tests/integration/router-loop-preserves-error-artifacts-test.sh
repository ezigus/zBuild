#!/usr/bin/env bash
# Integration: Wave 19-I Fix B (#743) — preserve claude raw output on rc≠0.
#
# Dogfood 20260607181657-82646 iters 1+2 ran build's claude subprocess to
# rc=1 with EMPTY stdout AND empty stderr. The actual $json_file (claude's
# full JSON envelope with .is_error, .error, .result, .num_turns) and
# $stderr_file are deleted at route.sh:993 immediately after the
# diagnostic event fires — so every future "why did claude rc=N?"
# forensic round re-encounters the gap.
#
# Fix: on rc≠0 (that's NOT a Fix-A sentinel rescue), copy json_file and
# stderr_file into ZBUILD_ARTIFACT_DIR/stage-io/<stage>-iter<N>-error.*
# BEFORE the existing rm -f. Emit router.loop.iter.error.diagnostic with
# parsed fields so the operator can grep events.jsonl for "why" without
# opening files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "router_loop: preserve rc≠0 diagnostic artifacts (Wave 19-I Fix B, #743)"
setup_test_env "router-loop-preserves-error-artifacts"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
export ZBUILD_RUN_ID="loop-error-preserve-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

# Stub claude: emits a JSON envelope describing an error (is_error=true,
# error=max_turns_reached, num_turns=25), plus a line to stderr, then
# exits rc=1. NO LOOP_COMPLETE in .result (so the Fix-A sentinel rescue
# does NOT trigger — this iter must hit the preservation path).
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
if [[ -n "$MARK_FILE" ]]; then
    assert_pass "[SPEC-1] MARK_FILE non-empty at setup"
else
    assert_fail "[SPEC-1] MARK_FILE non-empty at setup" "MARK_FILE is empty or unset"
fi
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
mark="$MARK_FILE"
echo "iter" >> "\$mark"
# Stop after 2 iters to bound the test (no-progress safety net will fire).
if [[ "\$(wc -l < "\$mark" 2>/dev/null | tr -d ' ')" -ge 2 ]]; then
    jq -n --arg r 'forced termination' '{type:"result", subtype:"success", is_error:false, result:\$r, num_turns:5, usage:{input_tokens:5, output_tokens:5}}'
    exit 0
fi
# Iter 1: error envelope + stderr + rc=1.
printf 'CLI internal warning: tool limit nearing\n' >&2
jq -n '{type:"result", subtype:"error_max_turns", is_error:true, error:"max_turns_reached", result:"", num_turns:25, usage:{input_tokens:100, output_tokens:0}}'
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
assert_contains "[SPEC-2] mock-claude bakes concrete MARK_FILE path at write time" \
    "$(cat "$TEST_TEMP_DIR/bin/claude")" "$MARK_FILE"
mock_body="$(cat "$TEST_TEMP_DIR/bin/claude")"
if ! grep -qF '/tmp/mark' <<< "$mock_body" 2>/dev/null; then
    assert_pass "[SPEC-3] mock-claude has no /tmp/mark fallback"
else
    assert_fail "[SPEC-3] mock-claude has no /tmp/mark fallback" "found /tmp/mark in mock body"
fi
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      tail_lines: 5
YAML

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "build prompt — preserve-error fixture" > "$PROMPT_FILE"

DRIVER="$TEST_TEMP_DIR/driver.sh"
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
export ZBUILD_ARTIFACT_DIR="$ZBUILD_ARTIFACT_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export MARK_FILE="$MARK_FILE"

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 10
rc=\$?
set -e
EOF

DRIVER_STDERR="$TEST_TEMP_DIR/driver.stderr.txt"
bash "$DRIVER" >/dev/null 2>"$DRIVER_STDERR" || true

print_test_section "rc=1 iter preserves diagnostic artifacts + emits diagnostic event"

# T1: loop.iteration.error event STILL fires for the rc=1 iter (regression
# guard — Fix B doesn't suppress the existing event).
err_count="$(jq -c 'select(.type=="loop.iteration.error" and .data.rc=="1")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1: loop.iteration.error event still emitted on rc=1" "1" "$err_count"

# T2: NEW router.loop.iter.error.diagnostic event emitted.
diag_count="$(jq -c 'select(.type=="router.loop.iter.error.diagnostic")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T2: router.loop.iter.error.diagnostic emitted" "1" "$diag_count"

# T3: diagnostic event has parsed is_error=true from the stub's JSON.
diag_is_error="$(jq -r 'select(.type=="router.loop.iter.error.diagnostic") | .data.is_error' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T3: diagnostic event is_error=true (parsed from JSON envelope)" "true" "$diag_is_error"

# T4: diagnostic event has parsed error_text.
diag_err="$(jq -r 'select(.type=="router.loop.iter.error.diagnostic") | .data.error_text' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T4: diagnostic event error_text=max_turns_reached" "max_turns_reached" "$diag_err"

# T5: diagnostic event has parsed num_turns.
diag_turns="$(jq -r 'select(.type=="router.loop.iter.error.diagnostic") | .data.num_turns' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T5: diagnostic event num_turns=25" "25" "$diag_turns"

# T6: preserved JSON artifact exists at predictable path.
RAW_JSON_PATH="$ZBUILD_ARTIFACT_DIR/stage-io/build-iter1-error.raw-claude-output.json"
if [[ -s "$RAW_JSON_PATH" ]]; then
    assert_pass "T6: raw-claude-output.json preserved at predictable path"
    _err_json="$(jq -r '.error // empty' "$RAW_JSON_PATH" 2>/dev/null || true)"
    if grep -q "max_turns_reached" <<< "$_err_json"; then
        assert_pass "T7: preserved JSON contains the .error field intact"
    else
        assert_fail "T7: preserved JSON should contain .error=max_turns_reached" "missing"
    fi
else
    assert_fail "T6: raw-claude-output.json MUST exist at $RAW_JSON_PATH" "not found"
fi

# T8: preserved stderr artifact exists with the stderr line from the stub.
RAW_STDERR_PATH="$ZBUILD_ARTIFACT_DIR/stage-io/build-iter1-error.raw-claude-stderr.txt"
if [[ -s "$RAW_STDERR_PATH" ]]; then
    assert_pass "T8: raw-claude-stderr.txt preserved at predictable path"
    if grep -q "tool limit nearing" "$RAW_STDERR_PATH"; then
        assert_pass "T9: preserved stderr contains the original line"
    else
        assert_fail "T9: preserved stderr should contain 'tool limit nearing'" "missing"
    fi
else
    assert_fail "T8: raw-claude-stderr.txt MUST exist at $RAW_STDERR_PATH" "not found"
fi

# T10: diagnostic event surfaces the preserved-file paths.
diag_json_path="$(jq -r 'select(.type=="router.loop.iter.error.diagnostic") | .data.raw_json_path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T10: diagnostic event raw_json_path matches the preserved file" "$RAW_JSON_PATH" "$diag_json_path"

# T11: loop path also surfaces error_max_turns to driver stderr (#762).
# The mock claude returns subtype=error_max_turns; the router must emit a
# clear human-readable line before the rc=1 logging so terminal users see why.
DRIVER_STDERR_FILE="${DRIVER_STDERR:-}"
if [[ -z "$DRIVER_STDERR_FILE" || ! -f "$DRIVER_STDERR_FILE" ]]; then
    # Fallback: some tests pipe driver output to a known temp file
    DRIVER_STDERR_FILE="$TEST_TEMP_DIR/driver.stderr.txt"
fi
if [[ -f "$DRIVER_STDERR_FILE" ]] && grep -qE 'claude max_turns reached \(turns=[0-9]+' "$DRIVER_STDERR_FILE"; then
    assert_pass "T11: loop-path stderr surfaces 'claude max_turns reached' human-readable line"
else
    assert_fail "T11: loop-path stderr MUST surface human-readable max_turns line" \
        "DRIVER_STDERR_FILE=$DRIVER_STDERR_FILE present=$([[ -f "$DRIVER_STDERR_FILE" ]] && echo yes || echo no)"
fi

# T12: legacy terse warn line is REPLACED by the human-readable message when
# subtype=error_max_turns. The "route_to_model_loop: claude rc=" prefix MUST
# NOT appear when the new clear message is shown.
if [[ -f "$DRIVER_STDERR_FILE" ]]; then
    set +e
    legacy_warn_count="$(grep -c 'route_to_model_loop: claude rc=' "$DRIVER_STDERR_FILE" 2>/dev/null)"
    set -e
    if [[ "$legacy_warn_count" -eq 0 ]]; then
        assert_pass "T12: legacy terse warn line replaced by human-readable message"
    else
        assert_fail "T12: legacy 'route_to_model_loop: claude rc=...' should NOT coexist with new clear line" \
            "found $legacy_warn_count legacy warn lines"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
