#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — the chokepoint contract (ADR-004,
# ADR-043; #2379). Every prompt passes through it; it takes private paths out
# and changes nothing else. It needs no scope manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction — chokepoint contract (ADR-004, #2379)"

setup_test_env "core-redaction"
INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ZBUILD_REPO_ROOT"

cat > "$INPUT" <<'TXT'
Edit src/included/foo.ts and read /etc/hosts.
The token lives in .env and deploy/id_rsa.
```
cat config/server.pem
```
TXT

print_test_section "needs no scope manifest"
rc=0; apply_scope_redaction "$INPUT" "$OUTPUT" "" "" 0 >/dev/null 2>&1 || rc=$?
assert_eq "redacts with no scope manifest" "0" "$rc"
_o="$(cat "$OUTPUT")"

print_test_section "takes private paths out, keeps the rest"
assert_contains "a repository path is kept" "$_o" "src/included/foo.ts"
assert_contains "a path outside the repository is kept" "$_o" "/etc/hosts"
for _p in .env deploy/id_rsa config/server.pem; do
    assert_eq "private path taken out: $_p" "0" "$(grep -cF -- "$_p" <<< "$_o" || true)"
done
assert_contains "a private path inside a code fence is taken out too" "$_o" "cat <private>"
assert_eq "no out-of-scope marker" "0" "$(grep -c 'out-of-scope-context' <<< "$_o" || true)"

print_test_section "idempotent"
cp "$OUTPUT" "$TEST_TEMP_DIR/once.txt"
apply_scope_redaction "$TEST_TEMP_DIR/once.txt" "$TEST_TEMP_DIR/twice.txt" "" "" 0 >/dev/null 2>&1
assert_eq "applying it twice changes nothing" "$(cat "$TEST_TEMP_DIR/once.txt")" "$(cat "$TEST_TEMP_DIR/twice.txt")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
