#!/usr/bin/env bash
# tests/unit/run-tests-total-note-test.sh — issue #1663
#
# The --tier all aggregation must accumulate skipped AND timed-out counts from
# every tier's summary note, including combined "(N skipped, N timed out)" notes
# that the old regex failed to parse. The total: line must carry both counts.
#
# Hermetic: all four file-tiers, mutation, and lint are stubbed via env vars so
# the real suite never runs inside the real suite.
#
# SPEC-1  CHANGE  skip from combined-note tier (N skipped, N timed out) accumulates
# SPEC-2  CHANGE  timed-out count from combined-note tier appears in total: line
# SPEC-3  GUARD   bare-(N skipped) tier still accumulates skip count correctly
# SPEC-4  (in run-tests-tier-concurrency-test.sh — no-note case verified there)
# SPEC-5  CHANGE  _rt_build_note helper function is present in run-tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh total: note aggregation (#1663)"
setup_test_env "run-tests-total-note"

EMPTY_DIR="$TEST_TEMP_DIR/empty"
EMPTY_MUT="$TEST_TEMP_DIR/empty-mut"
mkdir -p "$EMPTY_DIR" "$EMPTY_MUT"

# ─── Fixture ─────────────────────────────────────────────────────────────────
# unit/: one pass, one skip, one hang → "unit: 2/3 passed (1 skipped, 1 timed out)"
# integration/: one pass, one skip  → "integration: 2/2 passed (1 skipped)"
# e2e/, golden/: one instant pass each → no note
FIX="$TEST_TEMP_DIR/fix"
for t in unit integration e2e golden; do
    mkdir -p "$FIX/$t"
done

# pass file — instant exit 0
for t in unit integration e2e golden; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/$t/a-pass-test.sh"
    chmod +x "$FIX/$t/a-pass-test.sh"
done

# skip file — records one skip entry, exits 0 (counts as pass in totals)
for t in unit integration; do
    cat > "$FIX/$t/b-skip-test.sh" <<'SKIPFIX'
#!/usr/bin/env bash
[[ -n "${ZBUILD_TEST_SKIP_LOG:-}" ]] && echo "b-skip-test.sh: skipped" >> "$ZBUILD_TEST_SKIP_LOG"
exit 0
SKIPFIX
    chmod +x "$FIX/$t/b-skip-test.sh"
done

# hang file in unit/ only — sleep 30 so the per-file timeout fires
printf '#!/usr/bin/env bash\nsleep 30\n' > "$FIX/unit/c-hang-test.sh"
chmod +x "$FIX/unit/c-hang-test.sh"

# _all_fix — run --tier all against the fixture with tier concurrency disabled
# (serial path) so the hang in unit doesn't race the other tiers, and with a
# short per-file timeout so the test finishes in ~2–3 s total.
_all_fix() {
    local out_f="$TEST_TEMP_DIR/o.txt" rc=0
    env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
        -u ZBUILD_TIER_CONCURRENCY -u ZBUILD_TIER_BUDGET -u UPDATE_GOLDEN \
        ZBUILD_TESTS_DIR="$FIX" \
        ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
        ZBUILD_CORE_DIR="$EMPTY_DIR" \
        ZBUILD_MUTATION_DIR="$EMPTY_MUT" \
        ZBUILD_LINT_CMD=true \
        ZBUILD_PARALLEL_SAFE_TIERS="unit integration e2e golden" \
        ZBUILD_TIER_CONCURRENCY=0 \
        ZBUILD_TEST_PARALLEL_JOBS=0 \
        ZBUILD_TEST_FILE_TIMEOUT=2 \
        ZBUILD_TEST_KILL_GRACE=1 \
        bash "$RUN_TESTS" --tier all \
        >"$out_f" 2>/dev/null || rc=$?
    _OUT="$(cat "$out_f")"
    _RC="$rc"
}

_all_fix

# ─── [SPEC-1] CHANGE: combined-note tier's skip count accumulates ────────────
# unit emits "(1 skipped, 1 timed out)"; old regex missed this tier's skip count.
# Baseline: total shows only integration's 1 skip → "1 skipped" in total:.
# HEAD: both unit and integration contribute → "2 skipped" in total:.
assert_eq "[SPEC-1] skip from combined-note tier accumulates: total: shows 2 skipped" "1" \
    "$(printf '%s\n' "$_OUT" | grep -cF '2 skipped')"

# ─── [SPEC-2] CHANGE: combined-note tier's timed-out count appears in total: ──
# Baseline: total_timedout accumulator didn't exist → total: never shows timed out.
# HEAD: 1 timed out from unit propagates to total:.
assert_eq "[SPEC-2] total: line shows 1 timed out from combined-note tier" "1" \
    "$(printf '%s\n' "$_OUT" | grep '^total:' | grep -cF '1 timed out')"

# The total: line must carry both counts together in the correct format.
assert_eq "[SPEC-2b] total: line format: N/M passed (2 skipped, 1 timed out)" "1" \
    "$(printf '%s\n' "$_OUT" | grep -cE '^total: [0-9]+/[0-9]+ passed \(2 skipped, 1 timed out\)$')"

# ─── [SPEC-3] GUARD: bare-(N skipped) tier still accumulates correctly ────────
# integration emits "(1 skipped)" — the format that worked before. Verify it
# still contributes to total_skipped after the regex change.
assert_eq "[SPEC-3] integration tier emits bare-(1 skipped) summary" "1" \
    "$(printf '%s\n' "$_OUT" | grep -cE '^integration: 2/2 passed \(1 skipped\)$')"

# ─── [SPEC-5] CHANGE: _rt_build_note helper function exists in run-tests.sh ──
# Structural guard: the refactor extracted the note-building logic into a named
# function. At merge-base this function does not exist.
assert_eq "[SPEC-5] _rt_build_note function defined in run-tests.sh" "1" \
    "$(grep -cF '_rt_build_note()' "$RUN_TESTS")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
