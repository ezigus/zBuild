#!/usr/bin/env bash
# tests/fixtures/slow-mock-claude.sh — reusable slow mock for #491.
#
# Sleeps for SLOW_MOCK_CLAUDE_SLEEP seconds (default 1.5) BEFORE emitting a
# response. Used by the stage-io ordering invariant test to widen the timing
# gap between the input-phase banner (emitted before claude runs) and the
# output-phase banner (emitted after claude returns) — so the ordering can be
# proven via timestamp delta with tolerance for scheduler jitter.
#
# When SLOW_MOCK_CLAUDE_MARK is set, appends a UTC ms timestamp + caller marker
# to that file each invocation so callers can correlate independently.
#
# Branches on argv: if --output-format json is present, emits an
# Anthropic-shaped envelope ({result, usage}); otherwise plain text.

# Note: stdbuf -oL -eL is applied by the test runner, not this fixture, so the
# mock itself stays portable across Linux/macOS.

_sleep="${SLOW_MOCK_CLAUDE_SLEEP:-1.5}"
_mark="${SLOW_MOCK_CLAUDE_MARK:-}"
_payload="${SLOW_MOCK_CLAUDE_PAYLOAD:-mock-claude-response}"

if [[ -n "$_mark" ]]; then
    # Capture "begin" timestamp BEFORE the sleep so the test can prove the
    # input banner was emitted earlier (or at least concurrently with) this point.
    # EPOCHREALTIME is bash 5+ "<sec>.<usec>"; convert to integer ms.
    _us="${EPOCHREALTIME/./}"
    printf '%s %s begin\n' "$(( 10#${_us} / 1000 ))" "$0" >> "$_mark"
fi

sleep "$_sleep"

if [[ -n "$_mark" ]]; then
    _us="${EPOCHREALTIME/./}"
    printf '%s %s end\n' "$(( 10#${_us} / 1000 ))" "$0" >> "$_mark"
fi

# Detect JSON envelope mode by scanning argv.
_json_mode=0
for _a in "$@"; do
    if [[ "$_a" == "--output-format" ]]; then
        _json_mode=1
        break
    fi
done

if [[ "$_json_mode" -eq 1 ]]; then
    # Minimal envelope; downstream parser only cares about .result + .usage.
    jq -n --arg r "$_payload" \
        '{result:$r, usage:{input_tokens:1, output_tokens:1}}'
else
    printf '%s\n' "$_payload"
fi

exit 0
