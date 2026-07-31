#!/usr/bin/env bash
# tests/unit/run-tests-timeout-report-test.sh — issue #1613
#
# run-tests.sh must report a file killed at its per-file time bound as a TIMEOUT,
# not as an ordinary assertion FAIL. Conflating the two is what made #1609
# unsolvable: two investigations chased fabricated assertion failures that were
# only a timeout, one of them filing a bogus durability bug against
# core/state/atomic.sh.
#
# Hermetic: ZBUILD_TESTS_DIR + ZBUILD_PLUGINS_DIR + ZBUILD_CORE_DIR + an empty
# ZBUILD_MUTATION_DIR point every discovery root at fixtures, so the real suite
# is never executed (and this file can therefore run inside the real suite).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh timeout reporting (#1613)"
setup_test_env "run-tests-timeout-report"

EMPTY="$TEST_TEMP_DIR/empty"
mkdir -p "$EMPTY"

# ─── Fixture: one instant pass, one genuine failure, one file that hangs ─────
FIX="$TEST_TEMP_DIR/fix"
mkdir -p "$FIX/unit"
printf '#!/usr/bin/env bash\nexit 0\n'                                   > "$FIX/unit/a-ok-test.sh"
printf '#!/usr/bin/env bash\necho "genuine assertion broke" >&2\nexit 1\n' > "$FIX/unit/b-broken-test.sh"
printf '#!/usr/bin/env bash\necho "MARKER_BEFORE_HANG"\nsleep 30\n'      > "$FIX/unit/c-hang-test.sh"
chmod +x "$FIX/unit"/*.sh

# _run_unit_tier <timeout_s> — run the unit tier against the fixture with the
# per-file bound forced low. Captures merged stdout+stderr into $OUT, rc into $RC.
_run_unit_tier() {
    local bound="$1"
    set +e
    OUT="$(ZBUILD_TESTS_DIR="$FIX" \
           ZBUILD_PLUGINS_DIR="$EMPTY" \
           ZBUILD_CORE_DIR="$EMPTY" \
           ZBUILD_MUTATION_DIR="$EMPTY" \
           ZBUILD_TEST_FILE_TIMEOUT="$bound" \
           ZBUILD_TEST_JOBS=1 \
           bash "$RUN_TESTS" --tier unit 2>&1)"
    RC=$?
    set -e
}

_run_unit_tier 2

# ─── SPEC-1: the bound-exceeded file is labelled TIMEOUT, naming the bound ───
assert_eq "[SPEC-1] hung file reports TIMEOUT naming the bound, not FAIL" "1" \
    "$(printf '%s\n' "$OUT" | grep -cE '^unit: TIMEOUT .*c-hang-test\.sh \(exceeded 2s, rc=[0-9]+\)$')"

assert_eq "[SPEC-1] hung file does NOT report as an ordinary FAIL" "0" \
    "$(printf '%s\n' "$OUT" | grep -cE '^unit: FAIL .*c-hang-test\.sh$')"

# ─── SPEC-2: its output is still replayed, fenced as untrustworthy ───────────
# The output must survive (it is often the only clue about where the file hung),
# but a reader must not mistake it for findings.
assert_eq "[SPEC-2] timed-out file's captured output is still shown" "1" \
    "$(printf '%s\n' "$OUT" | grep -c 'MARKER_BEFORE_HANG')"

assert_eq "[SPEC-2] that output is marked UNTRUSTWORTHY" "1" \
    "$(printf '%s\n' "$OUT" | grep -c 'UNTRUSTWORTHY')"

# ─── SPEC-3: the tier summary counts timeouts separately ────────────────────
assert_eq "[SPEC-3] tier summary counts timeouts distinctly from failures" "1" \
    "$(printf '%s\n' "$OUT" | grep -cE '^unit: 1/3 passed \(1 timed out\)$')"

# ─── SPEC-4 (guard): a genuine failure is still a FAIL, unchanged ────────────
assert_eq "[SPEC-4] genuinely failing file still reports FAIL" "1" \
    "$(printf '%s\n' "$OUT" | grep -cE '^unit: FAIL .*b-broken-test\.sh$')"

assert_eq "[SPEC-4] genuine failure is not relabelled TIMEOUT" "0" \
    "$(printf '%s\n' "$OUT" | grep -cE '^unit: TIMEOUT .*b-broken-test\.sh')"

assert_eq "[SPEC-4] tier still exits non-zero when files fail" "1" "$RC"

# ─── SPEC-4b (guard): with no timeouts, the summary is byte-identical to before ─
# The bound is disabled, so the hung file is the only casualty removed; re-run
# with just the pass + genuine-failure files to prove the note is absent when
# nothing timed out (no stray "(0 timed out)").
rm -f "$FIX/unit/c-hang-test.sh"
_run_unit_tier 0
assert_eq "[SPEC-4b] no timeouts → summary carries no timeout note" "1" \
    "$(printf '%s\n' "$OUT" | grep -cE '^unit: 1/2 passed$')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
