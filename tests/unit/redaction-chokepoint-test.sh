#!/usr/bin/env bash
# Tests: redaction chokepoint enforcement (ARCHITECTURE.md §4 + §3)
# Greps the repo for raw model invocations outside core/redaction/ and core/router/.
# Any hit means a plugin or script is calling the LLM directly — a contract violation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "redaction — chokepoint scanner (ARCHITECTURE.md §3, §4)"
setup_test_env "redaction-chokepoint"

# ─── Scan patterns ────────────────────────────────────────────────────────────
# Patterns that indicate a raw LLM invocation:
#   1. `claude -p` or `claude --print` (direct claude CLI call)
#   2. `curl.*anthropic` or `curl.*anthropic.com` (raw HTTP to Anthropic API)
#   3. `anthropic.com` in non-comment, non-doc context
#
# Allowed locations (these are the ONLY places that may invoke the LLM):
#   - core/redaction/   (the chokepoint itself)
#   - core/router/      (routes calls through redaction)
#   - tests/            (test mocks are acceptable)
#   - legacy/           (frozen reference; disabled sentinel prevents execution)
#   - .git/             (version control internals)
#   - docs/             (documentation only)
#   - *.md              (markdown docs)

VIOLATIONS=()

# ─── Pattern 1: `claude -p` (direct LLM invocation) ─────────────────────────
# Exclude: tests/, legacy/, docs/, *.md, core/redaction/, core/router/
while IFS=: read -r file line content; do
    # Skip empty lines
    [[ -z "$file" ]] && continue
    # Skip allowed locations
    case "$file" in
        */tests/*|*/legacy/*|*/docs/*|*.md|*/core/redaction/*|*/core/router/*)
            continue ;;
        */.git/*)
            continue ;;
    esac
    VIOLATIONS+=("$file:$line: raw 'claude -p' invocation (must go through core/router)")
done < <({
    # Named extensions
    grep -rn 'claude -p\|claude --print' \
        --include="*.sh" --include="*.bash" \
        --exclude-dir=".git" \
        --exclude-dir="legacy" \
        --exclude-dir="tests" \
        --exclude-dir="docs" \
        "$REPO_ROOT" 2>/dev/null || true
    # Extensionless entry-point scripts (e.g. scripts/zbuild)
    find "$REPO_ROOT/scripts" -maxdepth 1 -type f ! -name "*.*" -perm -u+x 2>/dev/null | \
        xargs -I{} grep -n 'claude -p\|claude --print' {} /dev/null 2>/dev/null || true
} | grep -v '/core/redaction/' | grep -v '/core/router/' || true)

# ─── Pattern 2: curl to anthropic API ────────────────────────────────────────
while IFS=: read -r file line content; do
    [[ -z "$file" ]] && continue
    case "$file" in
        */tests/*|*/legacy/*|*/docs/*|*.md|*/core/redaction/*|*/core/router/*)
            continue ;;
        */.git/*)
            continue ;;
    esac
    VIOLATIONS+=("$file:$line: raw curl to Anthropic API (must go through core/router)")
done < <({
    grep -rn 'curl.*anthropic\|curl.*api\.anthropic' \
        --include="*.sh" --include="*.bash" \
        --exclude-dir=".git" \
        --exclude-dir="legacy" \
        --exclude-dir="tests" \
        --exclude-dir="docs" \
        "$REPO_ROOT" 2>/dev/null || true
    find "$REPO_ROOT/scripts" -maxdepth 1 -type f ! -name "*.*" -perm -u+x 2>/dev/null | \
        xargs -I{} grep -n 'curl.*anthropic\|curl.*api\.anthropic' {} /dev/null 2>/dev/null || true
} | grep -v '/core/redaction/' | grep -v '/core/router/' || true)

# ─── Report ───────────────────────────────────────────────────────────────────
if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
    assert_pass "chokepoint scan: no raw LLM invocations found outside allowed locations"
else
    for v in "${VIOLATIONS[@]}"; do
        assert_fail "chokepoint violation: $v"
    done
fi

# ─── Sentinel test: verify scanner CATCHES violations ────────────────────────
# Temporarily inject a fake claude invocation into a test scratch file,
# verify the scanner detects it, then remove it.
SCRATCH="$TEST_TEMP_DIR/scratch-violation.sh"
cat > "$SCRATCH" <<'VIOLATION'
#!/usr/bin/env bash
# This file intentionally contains a raw LLM invocation for testing the scanner.
response="$(claude -p "some prompt" --print --model claude-sonnet)"
VIOLATION

# Scan just the scratch file for the violation
scanner_violations=()
while IFS=: read -r file line content; do
    [[ -z "$file" ]] && continue
    scanner_violations+=("$file:$line")
done < <(grep -n 'claude -p\|claude --print' "$SCRATCH" 2>/dev/null || true)

if [[ ${#scanner_violations[@]} -gt 0 ]]; then
    assert_pass "chokepoint sentinel: scanner detects injected violation in $SCRATCH"
else
    assert_fail "chokepoint sentinel: scanner MISSED injected violation — scanner is broken"
fi

# Clean up the scratch file
rm -f "$SCRATCH"

# Verify scanner no longer finds the violation after cleanup
post_cleanup_violations=()
while IFS=: read -r file line content; do
    [[ -z "$file" ]] && continue
    post_cleanup_violations+=("$file:$line")
done < <(grep -rn 'claude -p\|claude --print' "$TEST_TEMP_DIR" 2>/dev/null || true)

if [[ ${#post_cleanup_violations[@]} -eq 0 ]]; then
    assert_pass "chokepoint sentinel: no violations after scratch file removed"
else
    assert_fail "chokepoint sentinel: unexpected violations after cleanup: ${post_cleanup_violations[*]}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
