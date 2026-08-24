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
#   1. a `claude` command line carrying `-p`/`--print` (direct claude CLI call).
#      The regex tolerates intervening args (e.g. `claude "${args[@]}" --print`)
#      so arg-ordering can't evade the scanner — #995-class accidental bypass.
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
#
# Audited exception (issue A3, redaction-by-construction plan):
#   - scripts/lib/gh-automation.sh :: gha_compute_similarity_llm sends only
#     PUBLIC GitHub issue/PR text for dedup scoring (never scope-sensitive
#     working-tree content), and runs as standalone GH-Actions automation with
#     no RUN_ID/events.jsonl/scope-manifest, so route_to_model's C6 precondition
#     is unsatisfiable. It is allowlisted BELOW by exact path — an intentional,
#     documented exemption, not an arg-ordering accident. See ADR-004 / ADR-020
#     v2 and the AUDITED-EXCEPTION marker in that file.

# Pattern 1 regex (ERE): a `claude` token followed (possibly after other args)
# by `--print` or a standalone `-p`. Shared by the main scan, the sentinel, and
# the gh-automation detection assertion so all three stay in lockstep.
P1_PATTERN='claude.*(--print|[[:space:]]-p([[:space:]]|$))'

VIOLATIONS=()

# ─── Pattern 1: `claude … -p/--print` (direct LLM invocation) ────────────────
# Exclude: tests/, legacy/, docs/, *.md, core/redaction/, core/router/
while IFS=: read -r file line content; do
    # Skip empty lines
    [[ -z "$file" ]] && continue
    # Skip full-comment lines — a documentation/comment mention is not a real
    # invocation (e.g. scripts/lib/test-helpers.sh mock-installer docs).
    _trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$_trimmed" == \#* ]] && continue
    # Skip allowed locations
    case "$file" in
        */tests/*|*/legacy/*|*/docs/*|*.md|*/core/redaction/*|*/core/router/*)
            continue ;;
        */.git/*)
            continue ;;
        */scripts/lib/gh-automation.sh)
            # AUDITED EXCEPTION (A3 / ADR-004 / ADR-020 v2): the only sanctioned
            # raw `claude` call — public GitHub text only, no scope-manifest
            # context, C6 unsatisfiable. Documented in-file + asserted below.
            continue ;;
    esac
    VIOLATIONS+=("$file:$line: raw 'claude -p/--print' invocation (must go through core/router)")
done < <({
    # Named extensions
    grep -rEn "$P1_PATTERN" \
        --include="*.sh" --include="*.bash" \
        --exclude-dir=".git" \
        --exclude-dir="legacy" \
        --exclude-dir="tests" \
        --exclude-dir="docs" \
        "$REPO_ROOT" 2>/dev/null || true
    # Extensionless entry-point scripts (e.g. scripts/zbuild)
    find "$REPO_ROOT/scripts" -maxdepth 1 -type f ! -name "*.*" -perm -u+x 2>/dev/null | \
        xargs -I{} grep -En "$P1_PATTERN" {} /dev/null 2>/dev/null || true
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

# ─── Audited exception: gh-automation.sh raw-claude call (A3) ────────────────
# The exemption must be BOTH detectable by the scanner (so it can't silently
# regrow via arg-ordering) AND documented in-file (so it stays intentional).
GHA_LIB="$REPO_ROOT/scripts/lib/gh-automation.sh"

# 1) The broadened Pattern-1 regex MUST detect gh-automation's real call shape.
#    (If this stops matching, the scanner has regressed to the #995-class
#    arg-ordering blind spot and the allowlist would be hiding nothing.)
#    Use a var + here-string (NOT `… | grep -q`) to avoid the SIGPIPE
#    antipattern the unit tier forbids (#1015).
_gha_scan="$(grep -En "$P1_PATTERN" "$GHA_LIB" 2>/dev/null || true)"
_gha_hits="$(grep -vE '^[0-9]+:[[:space:]]*#' <<< "$_gha_scan" || true)"
if [[ -n "$_gha_hits" ]]; then
    assert_pass "chokepoint: scanner detects gh-automation raw-claude shape (exempt via explicit allowlist, not arg-ordering)"
else
    assert_fail "chokepoint: scanner no longer detects gh-automation raw-claude shape — arg-ordering evasion regressed"
fi

# 2) The exempt call MUST carry its AUDITED-EXCEPTION marker so the allowlist
#    can never shelter an undocumented raw claude call.
if grep -q 'AUDITED-EXCEPTION' "$GHA_LIB" 2>/dev/null; then
    assert_pass "chokepoint: gh-automation.sh raw-claude exception carries AUDITED-EXCEPTION marker"
else
    assert_fail "chokepoint: gh-automation.sh is allowlisted but missing its AUDITED-EXCEPTION marker — undocumented raw claude call"
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
done < <(grep -En "$P1_PATTERN" "$SCRATCH" 2>/dev/null || true)

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
done < <(grep -rEn "$P1_PATTERN" "$TEST_TEMP_DIR" 2>/dev/null || true)

if [[ ${#post_cleanup_violations[@]} -eq 0 ]]; then
    assert_pass "chokepoint sentinel: no violations after scratch file removed"
else
    assert_fail "chokepoint sentinel: unexpected violations after cleanup: ${post_cleanup_violations[*]}"
fi

# ─── SPEC-6: permissions.sh lives inside core/router/ (the allowed zone) ─────
# #1919 (C10): permissions.sh writes the settings file that replaces
# --dangerously-skip-permissions. It must reside inside core/router/ so the
# chokepoint scanner's allowlist covers it by construction.
if [[ -f "$REPO_ROOT/core/router/permissions.sh" ]]; then
    assert_pass "[SPEC-6] permissions.sh exists inside core/router/ (chokepoint-exempt zone)"
else
    assert_fail "[SPEC-6] permissions.sh must exist inside core/router/ (chokepoint-exempt zone)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
