#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh
# Verifies the chokepoint refuses without scope, redacts out-of-scope paths,
# preserves code fences, and is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction — chokepoint contract (ADR-004)"

setup_test_env "core-redaction"
INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

# ─── Refuses without scope manifest ─────────────────────────────────────────
echo "hello world" > "$INPUT"

set +e
apply_scope_redaction "$INPUT" "$OUTPUT" "" >/dev/null 2>&1
rc=$?
set -e
assert_eq "refuses to emit when scope manifest is unset (fail-closed)" "1" "$rc"

set +e
apply_scope_redaction "$INPUT" "$OUTPUT" "/nonexistent/path" >/dev/null 2>&1
rc=$?
set -e
assert_eq "refuses to emit when scope manifest does not exist" "1" "$rc"

: > "$MANIFEST"
set +e
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "refuses to emit when scope manifest is empty" "1" "$rc"

# ─── Redacts out-of-scope paths ─────────────────────────────────────────────
cat > "$MANIFEST" <<EOF
+ src/included/
+ docs/
EOF
cat > "$INPUT" <<EOF
The file src/included/foo.ts is in scope.
But /etc/passwd is out of scope.
And ../../../sibling-repo/secrets.txt is also out.
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
assert_contains "in-scope path preserved" "$(cat "$OUTPUT")" "src/included/foo.ts"
assert_contains "out-of-scope marker present" "$(cat "$OUTPUT")" "<out-of-scope-context>"

if grep -q '/etc/passwd' "$OUTPUT" && ! grep -q '<out-of-scope-context>/etc/passwd' "$OUTPUT"; then
    assert_fail "/etc/passwd was NOT redacted" "$(cat "$OUTPUT")"
else
    assert_pass "/etc/passwd was redacted"
fi

# ─── Preserves code fences ──────────────────────────────────────────────────
cat > "$MANIFEST" <<EOF
+ src/
EOF
cat > "$INPUT" <<'EOF'
Outside the fence: /etc/passwd is leaked.
```bash
# Inside the fence, paths like /etc/passwd are preserved verbatim
cat /etc/passwd
```
After the fence: /etc/passwd is leaked again.
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
# The inside-fence occurrence must NOT be wrapped in markers
fence_lines="$(awk '/```/{n++; next} n==1' "$OUTPUT")"
if echo "$fence_lines" | grep -q '<out-of-scope-context>'; then
    assert_fail "code-fence contents were redacted (should be preserved verbatim)" "$fence_lines"
else
    assert_pass "code-fence contents preserved verbatim"
fi

# Outside-fence path must be wrapped
outside="$(awk '/```/{n++; next} n==0 || n==2' "$OUTPUT")"
if echo "$outside" | grep -q '<out-of-scope-context>'; then
    assert_pass "outside-fence path is redacted"
else
    assert_fail "outside-fence path was NOT redacted" "$outside"
fi

# ─── Idempotent (marker count stable across re-application) ─────────────────
cat > "$MANIFEST" <<EOF
+ src/
EOF
cat > "$INPUT" <<EOF
src/foo.ts is fine. /etc/passwd is not.
EOF
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null
count1="$(grep -c '<out-of-scope-context>' "$OUTPUT" || true)"
apply_scope_redaction "$OUTPUT" "$OUTPUT.2" "$MANIFEST" >/dev/null
count2="$(grep -c '<out-of-scope-context>' "$OUTPUT.2" || true)"
assert_eq "idempotent: marker count stable across re-application" "$count1" "$count2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
