#!/usr/bin/env bash
# tests/unit/lint-grep-c-test.sh — the `grep -c … || echo` lint rule (#1751).
#
#   SPEC-4 [change]: a scanned file containing the antipattern → rc=1, named
#   SPEC-5 [change]: only safe forms (`|| true`, assignment-outside) → rc=0
#   SPEC-6 [change]: legacy/ is excluded from the scan
#
# Plus the wiring assertions that keep the rule reachable: a linter nothing
# invokes is inert, which is how the original defect shipped twice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-grep-c — grep -c || echo detection (#1751)"
setup_test_env "lint-grep-c"

CHECKER="$REPO_ROOT/scripts/lib/lint-grep-c.sh"

# The bad form is assembled at runtime rather than written literally, so this
# file stays clean no matter how the scan roots are widened later.
BAD_LINE='count="$(grep -cE '"'"'^x'"'"' "$f" 2>/dev/null || echo 0)"'

# ─── SPEC-4: antipattern present → rc=1 ──────────────────────────────────────
print_test_section "4. bad pattern detected: exit 1"

FX_BAD="$TEST_TEMP_DIR/bad"
mkdir -p "$FX_BAD"
{
    echo '#!/usr/bin/env bash'
    echo "$BAD_LINE"
} > "$FX_BAD/offender.sh"

rc=0
out="$(bash "$CHECKER" "$FX_BAD" 2>&1)" || rc=$?
assert_eq "[SPEC-4] lint exits 1 when bad pattern is present" "1" "$rc"
assert_contains "[SPEC-4] lint names the offending file and line" "$out" "offender.sh:2"

# ─── SPEC-5: only safe forms → rc=0 ──────────────────────────────────────────
print_test_section "5. clean code: exit 0"

FX_OK="$TEST_TEMP_DIR/ok"
mkdir -p "$FX_OK"
cat > "$FX_OK/safe.sh" <<'EOF'
#!/usr/bin/env bash
# Both accepted forms must keep passing.
count="$(grep -cE '^x' "$f" 2>/dev/null || true)"
other=$(grep -c '^y' "$f") || other=0
EOF

rc=0
bash "$CHECKER" "$FX_OK" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-5] lint exits 0 when no bad pattern is present" "0" "$rc"

# The real tree must be clean, or the rule cannot be wired into CI at all.
rc=0
bash "$CHECKER" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-5] real scripts/ core/ plugins/ tree is clean" "0" "$rc"

# ─── SPEC-6: legacy/ excluded ────────────────────────────────────────────────
print_test_section "6. legacy/ directory excluded from scan"

FX_LEGACY="$TEST_TEMP_DIR/withlegacy"
mkdir -p "$FX_LEGACY/legacy/scripts"
{
    echo '#!/usr/bin/env bash'
    echo "$BAD_LINE"
} > "$FX_LEGACY/legacy/scripts/frozen.sh"

rc=0
bash "$CHECKER" "$FX_LEGACY" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-6] bad pattern under legacy/ is excluded from lint" "0" "$rc"

# ─── Wiring: the rule must actually run somewhere ────────────────────────────
print_test_section "7. wiring: CI configuration references lint-grep-c.sh"

pkg_lint="$(jq -r '.scripts.lint // ""' "$REPO_ROOT/package.json")"
assert_contains "[SPEC-4] package.json lint script includes lint-grep-c.sh" \
    "$pkg_lint" "lint-grep-c.sh"

assert_contains "[SPEC-5] .github/workflows/test.yml references lint-grep-c step" \
    "$(cat "$REPO_ROOT/.github/workflows/test.yml")" "lint-grep-c.sh"

assert_contains "[SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step" \
    "$(cat "$REPO_ROOT/.github/workflows/deferred-tracker.yml")" "if: failure()"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
