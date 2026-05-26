#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — issue #296 Δ-3
# Regression: allowlist must not be passed via a temp file (race window).
# Verifies (a) apply_scope_redaction produces correct output, and (b) does
# not create any mktemp file in TMPDIR during execution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "scope-redaction — no allowlist tempfile (#296 Δ-3)"

setup_test_env "scope-redaction-no-tempfile"
INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

# ─── Setup: a manifest with + entries, an input with both in- and out-of-scope ─
cat > "$MANIFEST" <<'EOF'
# Scope manifest
+ core/event-bus
+ plugins/agent/security-lens
EOF

cat > "$INPUT" <<'EOF'
Check core/event-bus/event-bus.sh and plugins/agent/security-lens/plugin.sh.
Also peek at scripts/forbidden/secret.sh while you're at it.
EOF

# ─── Use an isolated TMPDIR for the test so we can detect any mktemp ────────
ISOLATED_TMPDIR="$TEST_TEMP_DIR/isolated-tmp"
mkdir -p "$ISOLATED_TMPDIR"
before_count="$(find "$ISOLATED_TMPDIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"

TMPDIR="$ISOLATED_TMPDIR" apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null 2>&1

after_count="$(find "$ISOLATED_TMPDIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"

assert_eq "no tempfile created in TMPDIR during redaction" "$before_count" "$after_count"

# ─── Verify correctness: in-scope tokens kept, out-of-scope wrapped ─────────
if grep -q '<out-of-scope-context>scripts/forbidden/secret.sh</out-of-scope-context>' "$OUTPUT"; then
    assert_pass "out-of-scope token wrapped"
else
    assert_fail "out-of-scope token wrapped" "expected wrapper around scripts/forbidden/secret.sh; got: $(cat "$OUTPUT")"
fi

if grep -q 'core/event-bus/event-bus.sh' "$OUTPUT" \
   && ! grep -q '<out-of-scope-context>core/event-bus' "$OUTPUT"; then
    assert_pass "in-scope token preserved (core/event-bus)"
else
    assert_fail "in-scope token preserved (core/event-bus)" "got: $(cat "$OUTPUT")"
fi

if grep -q 'plugins/agent/security-lens/plugin.sh' "$OUTPUT" \
   && ! grep -q '<out-of-scope-context>plugins/agent/security-lens' "$OUTPUT"; then
    assert_pass "in-scope token preserved (plugins/agent/security-lens)"
else
    assert_fail "in-scope token preserved (plugins/agent/security-lens)" "got: $(cat "$OUTPUT")"
fi

# ─── Also verify --allowlist CSV merges cleanly ─────────────────────────────
TMPDIR="$ISOLATED_TMPDIR" apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" "scripts/forbidden" >/dev/null 2>&1
if grep -q 'scripts/forbidden/secret.sh' "$OUTPUT" \
   && ! grep -q '<out-of-scope-context>scripts/forbidden' "$OUTPUT"; then
    assert_pass "CSV allowlist entry merges with + entries"
else
    assert_fail "CSV allowlist entry merges with + entries" "got: $(cat "$OUTPUT")"
fi

after_csv_count="$(find "$ISOLATED_TMPDIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
assert_eq "no tempfile created with CSV allowlist either" "$before_count" "$after_csv_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
