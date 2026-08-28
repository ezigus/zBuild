#!/usr/bin/env bash
# tests/unit/lint-grep-c-test.sh — the `grep -c … || echo` lint rule (#1751).
#
#   SPEC-4 [change]: a scanned file containing the antipattern → rc=1, named
#   SPEC-5 [change]: only safe forms (`|| true`, assignment-outside) → rc=0
#   SPEC-6 [change]: legacy/ is excluded from the scan
#   SPEC-7 [change]: test files ARE scanned — the #1751 exemption let the
#                    defect that cost run 32886585375 through (#1969)
#   SPEC-8 [change]: an explicit `lint-grep-c:allow` marker suppresses one line,
#                    so the linter's own fixtures need no path exemption
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
BAD_LINE='count="$(grep -cE '"'"'^x'"'"' "$f" 2>/dev/null || echo 0)"'  # lint-grep-c:allow — fixture, not an instance

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

# `-c` in a later flag cluster is the same bug and must not slip through
# (review finding on PR #1785 — the first regex only looked at the cluster
# immediately after `grep`).
SPLIT_LINE='count="$(grep -E -c '"'"'^x'"'"' "$f" 2>/dev/null || echo 0)"'  # lint-grep-c:allow — fixture, not an instance
FX_SPLIT="$TEST_TEMP_DIR/split"
mkdir -p "$FX_SPLIT"
{
    echo '#!/usr/bin/env bash'
    echo "$SPLIT_LINE"
} > "$FX_SPLIT/split-flags.sh"

rc=0
bash "$CHECKER" "$FX_SPLIT" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-4] lint catches -c in a later flag cluster (grep -E -c)" "1" "$rc"

# GNU long form is the same bug.
LONG_LINE='count="$(grep --count '"'"'^x'"'"' "$f" 2>/dev/null || echo 0)"'  # lint-grep-c:allow — fixture, not an instance
FX_LONG="$TEST_TEMP_DIR/longform"
mkdir -p "$FX_LONG"
{
    echo '#!/usr/bin/env bash'
    echo "$LONG_LINE"
} > "$FX_LONG/longform.sh"

rc=0
bash "$CHECKER" "$FX_LONG" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-4] lint catches the GNU long form (grep --count)" "1" "$rc"

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

# ─── SPEC-7: test files are scanned ──────────────────────────────────────────
# #1969: the #1751 exemption assumed the only harm was an arithmetic abort under
# `set -e`. In a SPEC-tagged test the same expression yields "0\n0" — an
# assertion that can never pass — and the acceptance gate escalates that into a
# whole-run failure. plugins/tool/test/tests/test-test.sh:661 shipped exactly
# this and cost run 32886585375 four hours.
print_test_section "7. test files are scanned (#1969)"

FX_TESTS="$TEST_TEMP_DIR/testfiles"
mkdir -p "$FX_TESTS/tests/unit"
{
    echo '#!/usr/bin/env bash'
    echo "$BAD_LINE"
} > "$FX_TESTS/tests/unit/offender-test.sh"

rc=0
out="$(bash "$CHECKER" "$FX_TESTS" 2>&1)" || rc=$?
assert_eq "[SPEC-7] a *-test.sh under tests/ is scanned, not exempted" "1" "$rc"
assert_contains "[SPEC-7] the offending test file is named with file:line" \
    "$out" "offender-test.sh:2"

# Both halves of the old exemption are gone, not just one: a *-test.sh outside
# tests/, and a non-test name inside tests/.
FX_T2="$TEST_TEMP_DIR/testfiles2"
mkdir -p "$FX_T2/plugins/tool/x/tests"
{
    echo '#!/usr/bin/env bash'
    echo "$BAD_LINE"
} > "$FX_T2/plugins/tool/x/tests/helper.sh"

rc=0
bash "$CHECKER" "$FX_T2" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-7] a plain .sh under a tests/ dir is scanned" "1" "$rc"

# ─── SPEC-8: explicit per-line opt-out ───────────────────────────────────────
# The linter's own fixtures above are literal bad lines. They need to stay
# literal (assembling them from fragments hides what is being tested), so the
# escape hatch is an explicit marker on the source line — never a path rule,
# which is what failed in the first place.
print_test_section "8. lint-grep-c:allow suppresses a single line (#1969)"

FX_ALLOW="$TEST_TEMP_DIR/allow"
mkdir -p "$FX_ALLOW"
{
    echo '#!/usr/bin/env bash'
    printf '%s  # lint-grep-c:allow — fixture, not an instance\n' "$BAD_LINE"
} > "$FX_ALLOW/marked.sh"

rc=0
bash "$CHECKER" "$FX_ALLOW" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-8] a line marked lint-grep-c:allow is not reported" "0" "$rc"

# The marker is per-line, not per-file: a second, unmarked offender in the same
# file must still be caught.
FX_ALLOW2="$TEST_TEMP_DIR/allow2"
mkdir -p "$FX_ALLOW2"
{
    echo '#!/usr/bin/env bash'
    printf '%s  # lint-grep-c:allow\n' "$BAD_LINE"
    echo "$BAD_LINE"
} > "$FX_ALLOW2/mixed.sh"

rc=0
out="$(bash "$CHECKER" "$FX_ALLOW2" 2>&1)" || rc=$?
assert_eq "[SPEC-8] the marker is per-line: an unmarked sibling still fails" "1" "$rc"
assert_contains "[SPEC-8] only the unmarked line is reported" "$out" "mixed.sh:3"

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
