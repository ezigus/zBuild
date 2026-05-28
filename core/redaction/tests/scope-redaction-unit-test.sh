#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — co-located unit tests (Wave 4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction/scope-redaction.sh — co-located unit tests"
setup_test_env "scope-redaction-colocated"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

# ── Refuses without scope manifest (fail-closed) ─────────────────────────────
printf 'hello world\n' > "$INPUT"
set +e; apply_scope_redaction "$INPUT" "$OUTPUT" "" >/dev/null 2>&1; rc=$?; set -e
assert_eq "refuses: empty manifest path → rc=1" "1" "$rc"

: > "$MANIFEST"
set +e; apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null 2>&1; rc=$?; set -e
assert_eq "refuses: empty manifest → rc=1" "1" "$rc"

# ── Redacts out-of-scope paths ────────────────────────────────────────────────
cat > "$MANIFEST" <<'EOF'
+ src/included/
+ docs/
EOF

cat > "$INPUT" <<'EOF'
path: src/included/file.go
path: src/excluded/secret.go
path: docs/README.md
EOF

: > "$ZBUILD_EVENTS_JSONL"
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST"
out="$(cat "$OUTPUT")"

if printf '%s\n' "$out" | grep -q "src/included/file.go"; then
    assert_pass "in-scope path is preserved"
else
    assert_fail "in-scope path is preserved" "missing: src/included/file.go"
fi

# Out-of-scope path is wrapped in <out-of-scope-context> tags (not deleted)
if printf '%s\n' "$out" | grep -q "out-of-scope-context"; then
    assert_pass "out-of-scope path is wrapped in out-of-scope-context tags"
else
    assert_fail "out-of-scope path is wrapped in out-of-scope-context tags" "no marker found in output"
fi

# ── apply_scope_redaction emits redaction.applied event ───────────────────────
assert_event_emitted "apply_scope_redaction emits redaction.applied" "$ZBUILD_EVENTS_JSONL" "redaction.applied"

cleanup_test_env
print_test_results
