#!/usr/bin/env bash
# Integration Tests: scripts/run-mutation.sh — infra outcomes are NON-FATAL (#1184)
#
# A worktree-add / patch failure that survives the runner's retries+verify is a
# transient MAINTENANCE signal, not a coverage gap. This test proves such an
# "infra" outcome:
#   - is EXCLUDED from the `mutation: P/T passed` score,
#   - is surfaced on a distinct `mutation-infra:` line,
#   - leaves the harness exit code 0 (does not fail the run), and
#   - does NOT roll up into test verdict=fail (via the shared parse + framework
#     result helpers that feed test-results.json).
#
# Fixtures patch/test INSIDE each throwaway HEAD worktree (never the live tree),
# so _assert_clean_targets stays satisfied on a clean dev tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/framework-result.sh
source "$REPO_ROOT/scripts/lib/framework-result.sh"
# shellcheck source=../../plugins/tool/test/lib/parse.sh
source "$REPO_ROOT/plugins/tool/test/lib/parse.sh"

print_test_header "scripts/run-mutation.sh — infra outcomes are non-fatal (#1184)"

setup_test_env "mutation-infra-nonfatal"

RUNNER="$REPO_ROOT/scripts/run-mutation.sh"

# The runner's _assert_clean_targets refuses on a dirty dev tree; skip rather
# than false-fail (mirrors mutation-parallel-equivalence-test.sh).
_dirty="$( { git -C "$REPO_ROOT" diff --name-only -- core plugins scripts tests
             git -C "$REPO_ROOT" ls-files --others --exclude-standard -- core plugins scripts tests
           } 2>/dev/null )"
if [[ -n "$_dirty" ]]; then
    print_test_section "SKIP — working tree dirty in mutation-target dirs"
    assert_pass "skipped: cannot exercise runner on a dirty tree (commit/stash first)"
    cleanup_test_env
    print_test_results
fi

FIXDIR="$TEST_TEMP_DIR/mutation"
mkdir -p "$FIXDIR"

# (a) INFRA: the mutated `## File` exists (verify passes), but the patch exits
#     non-zero against the verified checkout → classified infra (non-fatal).
cat > "$FIXDIR/01-patchfail.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Mutation
Synthetic infra outcome: verify passes (file present), then the patch fails.

## Patch
```bash
exit 1
```

## Expected failing test
`tests/unit/mutation-relevance-test.sh` — references run-mutation.sh.

## Result
Infra: the patch fails post-verify; a transient/maintenance signal, not a gap.

## Test
```bash
true
```
EOF

# (b) CAUGHT: dirties the worktree; the test demands an absent token → caught.
cat > "$FIXDIR/02-caught.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Mutation
Synthetic caught mutation alongside the infra one.

## Patch
```bash
printf 'MUTATED\n' > scripts/_zb_mut_fixture_caught2.sh
```

## Expected failing test
`tests/unit/mutation-relevance-test.sh` — references run-mutation.sh.

## Result
Caught: greps for HEALTHY in a file that contains MUTATED.

## Test
```bash
grep -q HEALTHY scripts/_zb_mut_fixture_caught2.sh
```
EOF

_run_fixture() {
    local jobs="$1" out="$2"
    set +e
    ZBUILD_MUTATION_DIR="$FIXDIR" \
    ZBUILD_MUTATION_PARALLEL_JOBS="$jobs" \
        bash "$RUNNER" > "$out" 2>/dev/null
    local rc=$?
    set -e
    printf '%s' "$rc"
}

# ─── Test 1: infra excluded from score; distinct line; exit 0 ────────────────
print_test_section "1. infra outcome excluded from score, on its own line, rc 0"
OUT="$TEST_TEMP_DIR/infra.out"
rc="$(_run_fixture 4 "$OUT")"
raw="$(cat "$OUT")"

assert_eq "run exits 0 despite an infra outcome" "0" "$rc"
# Caught counts, infra does NOT → denominator is 1, not 2.
assert_contains "score counts only genuine outcomes (1/1, infra excluded)" \
    "$raw" "mutation: 1/1 passed"
assert_contains "infra outcome surfaced on its own non-fatal line" \
    "$raw" "mutation-infra: 1 non-fatal"
assert_contains "patch-fail fixture classified INFRA (not FAIL)" \
    "$raw" "INFRA 01-patchfail.md  (patch failed after retries)"
if printf '%s\n' "$raw" | grep -q '^mutation: [0-9]*/[0-9]* passed$' \
   && ! printf '%s\n' "$raw" | grep -qE 'FAIL  01-patchfail'; then
    assert_pass "infra outcome does not emit a FAIL score row"
else
    assert_fail "infra outcome does not emit a FAIL score row" "$raw"
fi

# ─── Test 2: the shared parse roll-up does NOT yield test verdict=fail ───────
print_test_section "2. shared parse of the output → verdict pass (not fail)"
# _test_parse_summary is what the test plugin uses to derive the verdict that
# lands in test-results.json. rc 0 + a clean `mutation: 1/1 passed` line (infra
# excluded) must yield verdict=pass.
summary_line="$(_test_parse_summary "$raw" "$rc")"
verdict="${summary_line%%|*}"
assert_eq "infra-inclusive output rolls up to verdict=pass" "pass" "$verdict"

# framework_parse_mutation must record a clean measured score (infra excluded),
# so the downstream mutation-gate reads 1/1 — never a below-floor infra count.
mut_block="$(framework_parse_mutation "$raw")"
assert_json_key "mutation block status is measured" "$mut_block" ".status" "measured"
assert_json_key "mutation block score excludes infra (1/1)" "$mut_block" ".score" "1/1"

# ─── Test 3: an ALL-infra run is still rc 0 and verdict pass ─────────────────
print_test_section "3. all-infra run: rc 0, 0/0 score, verdict pass"
ALLDIR="$TEST_TEMP_DIR/mutation-allinfra"
mkdir -p "$ALLDIR"
cp "$FIXDIR/01-patchfail.md" "$ALLDIR/01-patchfail.md"

ALL_OUT="$TEST_TEMP_DIR/allinfra.out"
set +e
ZBUILD_MUTATION_DIR="$ALLDIR" ZBUILD_MUTATION_PARALLEL_JOBS=2 \
    bash "$RUNNER" > "$ALL_OUT" 2>/dev/null
all_rc=$?
set -e
all_raw="$(cat "$ALL_OUT")"

assert_eq "all-infra run exits 0" "0" "$all_rc"
assert_contains "all-infra score is 0/0 (nothing genuine to score)" \
    "$all_raw" "mutation: 0/0 passed"
all_summary="$(_test_parse_summary "$all_raw" "$all_rc")"
assert_eq "all-infra output rolls up to verdict=pass" "pass" "${all_summary%%|*}"

cleanup_test_env
print_test_results
