#!/usr/bin/env bash
# Tests: scripts/lib/coverage-report.py — untraced in-scope files must land in
# the denominator (#1761).
#
# Before the fix the per-file loop iterated `sorted(covered)`, i.e. only files
# the PS4 trace had seen. A file under core/ or scripts/lib/ that no test ever
# sources produced zero trace lines, so it contributed 0 to BOTH numerator and
# denominator — not 0/N. A wholly untested new file could not move the gate.
#
# SPEC-1[change]: an untraced in-scope file appears in the table at 0% and its
#                 executable lines are counted in the denominator.
# SPEC-2[change]: the reported total percentage is strictly lower than the
#                 traced-files-only computation over the same fixture.
# SPEC-3[guard]:  files that DO appear in the trace report the same covered /
#                 executable counts and per-file % as before.
# SPEC-4[guard]:  legitimately excluded files (under tests/, or named *-test.sh
#                 / *-unit-test.sh) stay out of both numerator and denominator.
# SPEC-5[guard]:  the disk walk is confined to core/ and scripts/lib/ — it must
#                 not sweep in legacy/, a frozen upstream import that is never
#                 executed and is not engine code (CLAUDE.md).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COV_REPORT="$REPO_ROOT/scripts/lib/coverage-report.py"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "coverage denominator includes untraced files (#1761)"
setup_test_env "coverage-untraced-file"

if [[ ! -f "$COV_REPORT" ]]; then
    assert_fail "coverage-report.py is present" "not found: $COV_REPORT"
    print_test_results
    exit 1
fi

# ─── Fixture repo ────────────────────────────────────────────────────────────
# core/traced.sh          1 executable line, present in the trace
# core/untraced.sh        3 executable lines, absent from the trace
# core/sub/deep-untraced.sh  2 executable lines, absent (proves recursion)
# core/tests/helper.sh    excluded by path       (SPEC-4)
# core/thing-test.sh      excluded by suffix     (SPEC-4)
# legacy/scripts/lib/old.sh  outside the scan roots (SPEC-5)
FAKE_ROOT="$TEST_TEMP_DIR/fake-repo"
mkdir -p "$FAKE_ROOT/core/sub" "$FAKE_ROOT/core/tests" "$FAKE_ROOT/legacy/scripts/lib"

printf '#!/usr/bin/env bash\necho traced\n'                  > "$FAKE_ROOT/core/traced.sh"
printf '#!/usr/bin/env bash\n_x=1\n_y=2\n_z=3\n'             > "$FAKE_ROOT/core/untraced.sh"
printf '#!/usr/bin/env bash\n_a=1\n_b=2\n'                   > "$FAKE_ROOT/core/sub/deep-untraced.sh"
printf '#!/usr/bin/env bash\n_h=1\n_i=2\n_j=3\n_k=4\n_l=5\n' > "$FAKE_ROOT/core/tests/helper.sh"
printf '#!/usr/bin/env bash\n_m=1\n_n=2\n_o=3\n_p=4\n_q=5\n' > "$FAKE_ROOT/core/thing-test.sh"
printf '#!/usr/bin/env bash\n_r=1\n_s=2\n_t=3\n_u=4\n_v=5\n' > "$FAKE_ROOT/legacy/scripts/lib/old.sh"

# Trace sees only core/traced.sh line 2.
TRACE_FILE="$TEST_TEMP_DIR/test.trace"
printf 'TRACE:%s/core/traced.sh:2:echo traced\n' "$FAKE_ROOT" > "$TRACE_FILE"

_out="$TEST_TEMP_DIR/cov-out.txt"
_rc=0
python3 "$COV_REPORT" "$TRACE_FILE" "$FAKE_ROOT" "0" >"$_out" 2>&1 || _rc=$?
_stdout="$(cat "$_out")"

assert_eq "coverage-report.py exits 0 with a floor of 0" "0" "$_rc"

# ─── SPEC-1[change] ─────────────────────────────────────────────────────────
# Executable-line counts: traced.sh 1, untraced.sh 3, sub/deep-untraced.sh 2.
# (The shebang counts as executable under the existing "non-blank, non-#"
# rule; `#!/usr/bin/env bash` starts with '#' so it does not.)
if grep -qE '^\| core/untraced\.sh \| 0 \| 3 \| 0\.0% \|$' "$_out"; then
    assert_pass "SPEC-1: untraced file is listed at 0/3 = 0.0%"
else
    assert_fail "SPEC-1: untraced file is listed at 0/3 = 0.0%" "table: $_stdout"
fi
if grep -qE '^\| core/sub/deep-untraced\.sh \| 0 \| 2 \| 0\.0% \|$' "$_out"; then
    assert_pass "SPEC-1: the walk recurses into subdirectories"
else
    assert_fail "SPEC-1: the walk recurses into subdirectories" "table: $_stdout"
fi
# Denominator = 1 (traced) + 3 (untraced) + 2 (deep) = 6; numerator = 1.
assert_contains "SPEC-1: untraced lines are in the denominator (Total: 1/6)" \
    "$_stdout" "Total: 1/6 lines"

# ─── SPEC-2[change] ─────────────────────────────────────────────────────────
# Traced-files-only over the same fixture is 1/1 = 100.0%. The corrected figure
# must be strictly lower. Derive it from the output rather than hardcoding, so
# the comparison is real arithmetic and not a restatement of SPEC-1.
_reported_pct="$(sed -n 's/^Total: [0-9]*\/[0-9]* lines (\([0-9.]*\)%)$/\1/p' "$_out")"
_traced_only_pct="100.0"
if [[ -n "$_reported_pct" ]] && awk -v a="$_reported_pct" -v b="$_traced_only_pct" \
        'BEGIN { exit !(a < b) }'; then
    assert_pass "SPEC-2: reported ${_reported_pct}% is strictly below the traced-only ${_traced_only_pct}%"
else
    assert_fail "SPEC-2: reported % must be strictly below the traced-only %" \
        "reported='$_reported_pct' traced_only='$_traced_only_pct'"
fi

# ─── SPEC-3[guard] ──────────────────────────────────────────────────────────
# The traced file's own row is untouched by the denominator fix: 1 of 1, 100%.
if grep -qE '^\| core/traced\.sh \| 1 \| 1 \| 100\.0% \|$' "$_out"; then
    assert_pass "SPEC-3: a traced file still reports its real covered/executable counts"
else
    assert_fail "SPEC-3: a traced file still reports its real covered/executable counts" \
        "table: $_stdout"
fi

# ─── SPEC-4[guard] ──────────────────────────────────────────────────────────
for _excluded in "core/tests/helper.sh" "core/thing-test.sh"; do
    if grep -qF "| $_excluded |" "$_out"; then
        assert_fail "SPEC-4: $_excluded stays excluded" "it appeared in the table"
    else
        assert_pass "SPEC-4: $_excluded stays excluded"
    fi
done

# ─── SPEC-5[guard] ──────────────────────────────────────────────────────────
# legacy/scripts/lib/old.sh matches the '/scripts/lib/' INCLUDE substring, so
# only the scan-root restriction keeps it out. Walking repo_root instead would
# silently add every legacy file to the denominator.
if grep -qF "legacy/scripts/lib/old.sh" "$_out"; then
    assert_fail "SPEC-5: legacy/ is not swept into the denominator" \
        "legacy file appeared in the table: $_stdout"
else
    assert_pass "SPEC-5: legacy/ is not swept into the denominator"
fi

# ─── Floor semantics still work off the corrected total ─────────────────────
# 1/6 = 16.7%. A floor of 50 must fail; a floor of 10 must pass.
_rc_high=0
python3 "$COV_REPORT" "$TRACE_FILE" "$FAKE_ROOT" "50" >/dev/null 2>&1 || _rc_high=$?
assert_eq "floor above the corrected total exits 1" "1" "$_rc_high"
_rc_low=0
python3 "$COV_REPORT" "$TRACE_FILE" "$FAKE_ROOT" "10" >/dev/null 2>&1 || _rc_low=$?
assert_eq "floor below the corrected total exits 0" "0" "$_rc_low"

# ─── Instrumentation-failure path is unchanged ──────────────────────────────
EMPTY_TRACE="$TEST_TEMP_DIR/empty.trace"
: > "$EMPTY_TRACE"
_rc_empty=0
python3 "$COV_REPORT" "$EMPTY_TRACE" "$FAKE_ROOT" "0" >/dev/null 2>&1 || _rc_empty=$?
assert_eq "an empty trace still exits 2 (instrumentation failure)" "2" "$_rc_empty"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
