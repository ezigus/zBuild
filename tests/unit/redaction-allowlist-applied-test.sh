#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — allowlist CSV is applied
# Regression for #606 Bug A1: callers that pass a non-empty allowlist CSV
# must see those paths preserved verbatim (not wrapped in
# <out-of-scope-context> markers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction — allowlist CSV is honored (#606)"

setup_test_env "redaction-allowlist-applied"
INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

cat > "$MANIFEST" <<EOF
+ src/included/
EOF

cat > "$INPUT" <<EOF
Files: tests/run-unit.sh
Also: tests/integration/foo.sh
EOF

# Non-empty allowlist with the test-suite paths
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" "tests/run-unit.sh,tests/integration/foo.sh" "0" >/dev/null

OUT_CONTENT="$(cat "$OUTPUT")"

assert_contains "allowlisted path tests/run-unit.sh preserved verbatim" \
    "$OUT_CONTENT" "tests/run-unit.sh"
assert_contains "allowlisted path tests/integration/foo.sh preserved verbatim" \
    "$OUT_CONTENT" "tests/integration/foo.sh"

# The CRITICAL regression check: no wrapper around an allowlisted path
if grep -q '<out-of-scope-context>tests/run-unit.sh' "$OUTPUT"; then
    assert_fail "allowlisted tests/run-unit.sh was wrapped in <out-of-scope-context>"
else
    assert_pass "allowlisted tests/run-unit.sh is NOT wrapped"
fi

if grep -q '<out-of-scope-context>tests/integration/foo.sh' "$OUTPUT"; then
    assert_fail "allowlisted tests/integration/foo.sh was wrapped in <out-of-scope-context>"
else
    assert_pass "allowlisted tests/integration/foo.sh is NOT wrapped"
fi

cleanup_test_env
print_test_results
