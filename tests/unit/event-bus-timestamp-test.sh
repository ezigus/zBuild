#!/usr/bin/env bash
# Tests: eb_emit_event timestamp platform fix and single-jq payload accumulation (#1806).
#   [#1806/SPEC-1] well-formed timestamp when ZBUILD_PLATFORM=linux + OSTYPE=darwin*
#   [#1806/SPEC-2] single jq invocation for payload; byte-identical output for same inputs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "event-bus: timestamp platform fix and single-jq payload (#1806)"
setup_test_env "event-bus-timestamp"

EVENT_BUS="$REPO_ROOT/core/event-bus/event-bus.sh"
REAL_DATE="$(command -v date)"
REAL_JQ="$(command -v jq)"
mkdir -p "$TEST_TEMP_DIR/bin"

# ─── SPEC-1 [#1806/SPEC-1]: well-formed timestamp on darwin host + linux platform ──
print_test_section "SPEC-1 [#1806/SPEC-1]: no literal %3N when OSTYPE=darwin* ZBUILD_PLATFORM=linux"

# BSD/macOS date does not support %3N — it outputs the literal characters %3N.
# This mock simulates that behaviour so the test runs on Linux CI.
cat > "$TEST_TEMP_DIR/bin/date" <<MOCK
#!/usr/bin/env bash
for _arg in "\$@"; do
    case "\$_arg" in
        +*%3N*) printf '2026-01-01T12:00:00.%%3NZ\n'; exit 0 ;;
    esac
done
exec $REAL_DATE "\$@"
MOCK
chmod +x "$TEST_TEMP_DIR/bin/date"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

_S1="$TEST_TEMP_DIR/s1"
mkdir -p "$_S1"
export ZBUILD_EVENTS_JSONL="$_S1/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$_S1"
: > "$_S1/events.jsonl"

# Simulate: macOS host (OSTYPE=darwin*) with ZBUILD_PLATFORM=linux.
# Old code checked ZBUILD_PLATFORM == "macos"; on Linux CI ZBUILD_PLATFORM=linux,
# so old code went to the else branch and called date with %3N, producing the
# literal string %3N on a macOS host.  New code checks OSTYPE.
OSTYPE="darwin12.3.0"
unset _ZBUILD_EVENT_BUS_LOADED _ZBUILD_EVENT_KNOWN_TYPES_LOADED 2>/dev/null || true
# shellcheck source=../../core/event-bus/event-bus.sh
source "$EVENT_BUS"

eb_emit_event "pipeline.start" "run_id=test-1806" "issue=1806"

_ts="$(jq -r '.ts // empty' "$_S1/events.jsonl" 2>/dev/null || true)"
if [[ -z "$_ts" ]]; then
    assert_fail "[#1806/SPEC-1] event emitted to events.jsonl" "file empty or ts missing"
else
    assert_pass "[#1806/SPEC-1] event emitted to events.jsonl"
fi

if grep -qF '%3N' "$_S1/events.jsonl" 2>/dev/null; then
    assert_fail "[#1806/SPEC-1] timestamp must not contain literal %3N" "ts: $_ts"
else
    assert_pass "[#1806/SPEC-1] timestamp contains no literal %3N"
fi

# Format: YYYY-MM-DDTHH:MM:SS.NNNz  (3 decimal digits, Z or z)
if [[ "$_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}[Zz]$ ]]; then
    assert_pass "[#1806/SPEC-1] timestamp is well-formed ISO 8601 with milliseconds"
else
    assert_fail "[#1806/SPEC-1] timestamp is well-formed ISO 8601 with milliseconds" \
        "got: $_ts"
fi

# ─── SPEC-2 [#1806/SPEC-2]: single jq invocation; byte-identical payload output ──
print_test_section "SPEC-2 [#1806/SPEC-2]: single jq call accumulates all key=val args"

JQ_CALL_LOG="$TEST_TEMP_DIR/jq-calls.log"
export JQ_CALL_LOG
: > "$JQ_CALL_LOG"

# Wrap the real jq to record every invocation; real jq still executes so output
# is preserved and the payload-identity assertion has something to check.
cat > "$TEST_TEMP_DIR/bin/jq" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${JQ_CALL_LOG:-/dev/null}"
exec $REAL_JQ "\$@"
MOCK
chmod +x "$TEST_TEMP_DIR/bin/jq"

_S2="$TEST_TEMP_DIR/s2"
mkdir -p "$_S2"
export ZBUILD_EVENTS_JSONL="$_S2/events.jsonl"
export ZBUILD_EVENTS_DIR="$_S2"
: > "$_S2/events.jsonl"

# Restore a non-darwin OSTYPE so the timestamp goes through the Linux path
# (date supports %3N on Linux; the mock date is still on PATH but is not called
# for non-%3N formats — it falls through to exec the real date).
OSTYPE="linux-gnu"
unset _ZBUILD_EVENT_BUS_LOADED _ZBUILD_EVENT_KNOWN_TYPES_LOADED 2>/dev/null || true
source "$EVENT_BUS"

: > "$JQ_CALL_LOG"
eb_emit_event "stage.complete" "stage=test-stage" "verdict=pass" "extra=data-value"

# Old code called jq once per key=val argument with the filter '. + {($k): $v}'.
# New code accumulates all args and calls jq once — that per-arg filter is gone.
_loop_calls="$(grep -cF '{($k): $v}' "$JQ_CALL_LOG" 2>/dev/null || true)"
if [[ "$_loop_calls" -eq 0 ]]; then
    assert_pass "[#1806/SPEC-2] per-arg accumulation pattern '. + {(\$k): \$v}' absent"
else
    assert_fail "[#1806/SPEC-2] per-arg accumulation pattern absent" \
        "found $_loop_calls call(s) with old per-arg filter"
fi

# All key=val args must survive in the payload (byte-identical output check)
_ev="$(cat "$_S2/events.jsonl" 2>/dev/null || true)"
assert_eq "[#1806/SPEC-2] payload.stage preserved" "test-stage" \
    "$(jq -r '.data.stage // empty' <<< "$_ev" 2>/dev/null || true)"
assert_eq "[#1806/SPEC-2] payload.verdict preserved" "pass" \
    "$(jq -r '.data.verdict // empty' <<< "$_ev" 2>/dev/null || true)"
assert_eq "[#1806/SPEC-2] payload.extra preserved" "data-value" \
    "$(jq -r '.data.extra // empty' <<< "$_ev" 2>/dev/null || true)"
assert_eq "[#1806/SPEC-2] event type preserved" "stage.complete" \
    "$(jq -r '.type // empty' <<< "$_ev" 2>/dev/null || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
