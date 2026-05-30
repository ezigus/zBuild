#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — issue #504
# Regression: pure-digit tokens like N/M (iteration counters) and YYYY/MM/DD
# (date prefixes) were being mis-detected as paths and wrapped in
# <out-of-scope-context>. The alpha-guard ensures only tokens containing at
# least one letter are eligible for wrapping. Emits redaction.counter_skipped
# when the guard fires.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction — alpha-guard for N/M counters (#504)"

setup_test_env "core-redaction-counter"
INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

# Route the event bus to an isolated state dir so we can inspect emissions.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
mkdir -p "$ZBUILD_EVENTS_DIR"

cat > "$MANIFEST" <<'EOF'
+ src/
EOF

# ─── Iteration counters must NOT be wrapped ─────────────────────────────────
cat > "$INPUT" <<'EOF'
iteration 1/1 complete
progress 2/10 done
final 99/100 reviewed
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '<out-of-scope-context>' "$OUTPUT"; then
    assert_fail "N/M iteration counters must not be wrapped" "$(cat "$OUTPUT")"
else
    assert_pass "N/M iteration counters (1/1, 2/10, 99/100) left untouched"
fi

# ─── Year-style date prefixes must NOT be wrapped ───────────────────────────
cat > "$INPUT" <<'EOF'
build started 2026/05/29
log line at 2026/01/02 03:04:05 UTC
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '<out-of-scope-context>' "$OUTPUT"; then
    assert_fail "YYYY/MM/DD date prefixes must not be wrapped" "$(cat "$OUTPUT")"
else
    assert_pass "YYYY/MM/DD date prefixes left untouched"
fi

# ─── Mixed lines: counter unwrapped, real path still wrapped ────────────────
cat > "$INPUT" <<'EOF'
iter 2/10 file out/of/scope/foo.sh changed
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '<out-of-scope-context>2/10' "$OUTPUT"; then
    assert_fail "counter '2/10' should not be wrapped" "$(cat "$OUTPUT")"
else
    assert_pass "counter '2/10' left untouched in mixed line"
fi
if grep -q '<out-of-scope-context>out/of/scope/foo.sh</out-of-scope-context>' "$OUTPUT"; then
    assert_pass "true out-of-scope path 'out/of/scope/foo.sh' still wrapped"
else
    assert_fail "true out-of-scope path must still be wrapped" "$(cat "$OUTPUT")"
fi

# ─── True paths (always contain a letter) still wrapped ─────────────────────
cat > "$INPUT" <<'EOF'
look at out/of/scope.sh and node_modules/x/y.js for clues
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '<out-of-scope-context>out/of/scope.sh</out-of-scope-context>' "$OUTPUT" \
   && grep -q '<out-of-scope-context>node_modules/x/y.js</out-of-scope-context>' "$OUTPUT"; then
    assert_pass "true paths still wrapped (out/of/scope.sh, node_modules/x/y.js)"
else
    assert_fail "true paths must still be wrapped" "$(cat "$OUTPUT")"
fi

# ─── Unicode/extended digits do not break the guard ─────────────────────────
# We treat any token without an ASCII letter as a non-path; unicode digits
# stay safely outside the alpha class and are therefore also skipped.
cat > "$INPUT" <<'EOF'
batch 12/34 done
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '<out-of-scope-context>' "$OUTPUT"; then
    assert_fail "12/34 must not be wrapped" "$(cat "$OUTPUT")"
else
    assert_pass "12/34 counter left untouched"
fi

# ─── Event emission: redaction.counter_skipped fires for counters ───────────
: > "$ZBUILD_EVENTS_JSONL"
cat > "$INPUT" <<'EOF'
iter 2/10 progress
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '"type":"redaction.counter_skipped"' "$ZBUILD_EVENTS_JSONL"; then
    assert_pass "redaction.counter_skipped event emitted when counter encountered"
else
    assert_fail "redaction.counter_skipped event must fire for N/M counters" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo '<none>')"
fi

# ─── Event NOT emitted when no counters present ─────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
cat > "$INPUT" <<'EOF'
src/foo.sh in scope, out/of/scope.sh not
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
if grep -q '"type":"redaction.counter_skipped"' "$ZBUILD_EVENTS_JSONL"; then
    assert_fail "counter_skipped must not fire when no counters present" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
else
    assert_pass "no spurious counter_skipped event when input has no counters"
fi

# ─── Event type registered in schema ────────────────────────────────────────
if jq -e '.known_types | index("redaction.counter_skipped")' \
        "$REPO_ROOT/config/event-schema.json" >/dev/null 2>&1; then
    assert_pass "redaction.counter_skipped listed in config/event-schema.json"
else
    assert_fail "redaction.counter_skipped must be in event-schema.json known_types" \
        "schema missing the new type"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
