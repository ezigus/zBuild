#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — idempotence
# Regression for #606 Bug A2: re-redacting already-redacted text must not
# nest <out-of-scope-context> markers. Per ADR-004 contract item 5
# ("Idempotent"), apply_scope_redaction(apply_scope_redaction(x)) == apply_scope_redaction(x).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction — idempotence (#606 Bug A2)"

setup_test_env "redaction-idempotence"
INPUT="$TEST_TEMP_DIR/prompt.txt"
PASS1="$TEST_TEMP_DIR/pass1.txt"
PASS2="$TEST_TEMP_DIR/pass2.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

cat > "$MANIFEST" <<EOF
+ src/included/
EOF

cat > "$INPUT" <<EOF
The file src/included/foo.ts is in scope.
But /etc/passwd is out of scope.
And ../../../sibling-repo/secrets.txt is also out.
References: tests/run-unit.sh and bin/some-tool.
EOF

# First pass
apply_scope_redaction "$INPUT" "$PASS1" "$MANIFEST" "" "0" >/dev/null
# Second pass over the already-redacted output
apply_scope_redaction "$PASS1" "$PASS2" "$MANIFEST" "" "0" >/dev/null

# Idempotence: pass1 == pass2
if diff -q "$PASS1" "$PASS2" >/dev/null 2>&1; then
    assert_pass "redactor is idempotent: redact(redact(x)) == redact(x)"
else
    assert_fail "redactor NOT idempotent — pass2 differs from pass1"
    echo "  --- pass1 vs pass2 diff ---"
    diff "$PASS1" "$PASS2" | head -20 | sed 's/^/    /'
fi

# Critical: no nested marker substrings appear after either pass
for label in pass1 pass2; do
    file="$TEST_TEMP_DIR/${label}.txt"
    if grep -q '<<out-of-scope-context>' "$file"; then
        assert_fail "$label contains nested marker substring '<<out-of-scope-context>'"
    else
        assert_pass "$label has no nested '<<out-of-scope-context>' substring"
    fi
    # Also: the literal closing tag should not itself be wrapped
    if grep -q '<out-of-scope-context>/out-of-scope-context' "$file"; then
        assert_fail "$label has re-wrapped closing tag (regex caught its own marker)"
    else
        assert_pass "$label closing tag is not re-wrapped"
    fi
done

cleanup_test_env
print_test_results
