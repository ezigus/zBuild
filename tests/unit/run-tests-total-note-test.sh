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
# SPEC-5  CHANGE  note rendering lives in exactly one helper (single-definition)
# SPEC-6  GUARD   timeout-only tier's PER-TIER line stays bare (N timed out) (#1613)
# SPEC-6b CHANGE  timeout-only tier reaches the total: line — new accumulator
# SPEC-7  GUARD   parse.sh still parses the widened total: line unchanged
# SPEC-8  GUARD   --files renders its note via the helper (defn must precede it)
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
    local fix_dir="${1:-$FIX}"
    local out_f="$TEST_TEMP_DIR/o.txt" rc=0
    env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
        -u ZBUILD_TIER_CONCURRENCY -u ZBUILD_TIER_BUDGET -u UPDATE_GOLDEN \
        ZBUILD_TESTS_DIR="$fix_dir" \
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
# Scoped to the total: line — an unrelated per-tier line containing "2 skipped"
# would otherwise satisfy (or, at 2 matches, spuriously fail) this assertion.
assert_eq "[SPEC-1] skip from combined-note tier accumulates: total: shows 2 skipped" "1" \
    "$(printf '%s\n' "$_OUT" | grep '^total:' | grep -cF '2 skipped')"

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

# ─── [SPEC-5] CHANGE: note rendering lives in EXACTLY one helper ─────────────
# The acceptance criterion is single-definition, not mere existence: asserting
# only that the function exists would still pass with a second inline renderer
# left behind, which is the duplication that caused this bug in the first place.
assert_eq "[SPEC-5] exactly one _rt_build_note definition" "1" \
    "$(grep -cF '_rt_build_note()' "$RUN_TESTS")"

# No inline note construction survives anywhere else in the script. The old
# third copy in the --files targeted-rerun path built its suffix with a literal
# printf; if any renderer reappears, this reddens.
assert_eq "[SPEC-5b] no inline '(N timed out)' printf renderer remains" "0" \
    "$(grep -cF "printf ' (%d timed out)'" "$RUN_TESTS")"

# All three emit sites route through the helper: --files, per-tier, and total:.
# Match the call SHAPE `$(_rt_build_note ` so the helper's own doc comment and
# definition are not counted as call sites.
assert_eq "[SPEC-5c] all three summary emit sites call _rt_build_note" "3" \
    "$(grep -cF '$(_rt_build_note ' "$RUN_TESTS")"

# ─── [SPEC-6/6b] a timeout-only tier renders a bare (N timed out) ────────────
# SPEC-6 is a GUARD: #1613 already made the PER-TIER line correct, and it stays
# correct here. SPEC-6b is the CHANGE: that count reaching the total: line is new.
# The combined-note fixture above never exercises a tier that timed out WITHOUT
# skipping — the shape the original issue named first. Separate fixture so the
# counts pinned by SPEC-1/2b above are undisturbed.
FIX2="$TEST_TEMP_DIR/fix2"
for t in unit integration e2e golden; do
    mkdir -p "$FIX2/$t"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX2/$t/a-pass-test.sh"
    chmod +x "$FIX2/$t/a-pass-test.sh"
done
printf '#!/usr/bin/env bash\nsleep 30\n' > "$FIX2/unit/c-hang-test.sh"
chmod +x "$FIX2/unit/c-hang-test.sh"

_all_fix "$FIX2"

assert_eq "[SPEC-6] timeout-only tier emits bare (1 timed out), no skip clause" "1" \
    "$(printf '%s\n' "$_OUT" | grep -cE '^unit: 1/2 passed \(1 timed out\)$')"

# Baseline had no total_timedout accumulator at all, so the total: line could
# never carry a timeout — with or without an accompanying skip.
assert_eq "[SPEC-6b] total: line is bare (1 timed out) with no skips anywhere" "1" \
    "$(printf '%s\n' "$_OUT" | grep -cE '^total: [0-9]+/[0-9]+ passed \(1 timed out\)$')"

# ─── [SPEC-8] GUARD: --files renders its note through the helper ─────────────
# The --files block executes BEFORE the rest of the script is parsed, so
# _rt_build_note must be defined above it. If it is moved back down beside its
# siblings, the call resolves to nothing, the command substitution yields empty,
# and the summary silently loses its note — verified by hand: the line degrades
# from "unit: 0/1 passed (1 timed out)" to "unit: 0/1 passed" with no error on
# stdout. run-tests-files-guard-test.sh does NOT catch it (it asserts on the
# TIMEOUT marker, not the summary note), so this assertion is the only guard.
_HANGDIR="$TEST_TEMP_DIR/filesfix"
mkdir -p "$_HANGDIR"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$_HANGDIR/h-test.sh"
chmod +x "$_HANGDIR/h-test.sh"
_FILES_OUT="$(ZBUILD_TEST_FILE_TIMEOUT=2 ZBUILD_TEST_KILL_GRACE=1 \
    bash "$RUN_TESTS" --files "$_HANGDIR/h-test.sh" 2>/dev/null || true)"

assert_eq "[SPEC-8] --files summary carries the timed-out note (helper is in scope)" "1" \
    "$(printf '%s\n' "$_FILES_OUT" | grep -cE '^unit: 0/1 passed \(1 timed out\)$')"

# ─── [SPEC-7] GUARD: parse.sh still consumes the widened total: line ─────────
# The issue requires the test plugin's parser to be unaffected by the format
# change. Its fixtures only ever carried the two OLD total: shapes, so feed it
# the new one directly and assert the contract it actually promises: counts come
# from per-suite lines (total: is skipped, #1234) and rc stays authoritative.
# shellcheck source=../../plugins/tool/test/lib/parse.sh
source "$REPO_ROOT/plugins/tool/test/lib/parse.sh"
_PARSE_RAW="$(printf '%s\n' \
    'unit: 2/3 passed (1 skipped, 1 timed out)' \
    'unit: TIMEOUT tests/unit/c-hang-test.sh (exceeded 2s, rc=124)' \
    'integration: 2/2 passed (1 skipped)' \
    '' \
    'total: 4/5 passed (2 skipped, 1 timed out)')"
_PARSE_OUT="$(_test_parse_summary "$_PARSE_RAW" 1)"

# passed = 2+2 from the per-suite lines only; the total: line must NOT be summed.
assert_eq "[SPEC-7] parse.sh sums per-suite lines and skips the total: aggregate" "4" \
    "$(printf '%s' "$_PARSE_OUT" | cut -d'|' -f2)"
assert_eq "[SPEC-7b] parse.sh recognises the widened summary (no fail-safe)" "1" \
    "$(printf '%s' "$_PARSE_OUT" | cut -d'|' -f5)"
assert_eq "[SPEC-7c] parse.sh honours rc as authoritative on the new shape" "fail" \
    "$(printf '%s' "$_PARSE_OUT" | cut -d'|' -f1)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
