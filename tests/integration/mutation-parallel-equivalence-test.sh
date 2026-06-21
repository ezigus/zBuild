#!/usr/bin/env bash
# Integration Tests: scripts/run-mutation.sh — serial≡parallel equivalence (#992)
#
# Asserts the parallel worktree runner produces byte-for-byte identical
# accounting to the serial path, leaves no stray worktrees, and that the
# per-mutant test is stdin-EOF-safe and time-bounded.
#
# Fixtures patch/test files INSIDE each throwaway HEAD worktree (never the live
# tree) so _assert_clean_targets — which inspects core/plugins/scripts/tests in
# the real REPO_ROOT — stays satisfied on a clean dev tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/run-mutation.sh — serial≡parallel worktree equivalence (#992)"

setup_test_env "mutation-parallel-equivalence"

RUNNER="$REPO_ROOT/scripts/run-mutation.sh"

# This test mutates per-mutant worktrees, not the live tree — but the runner's
# _assert_clean_targets still refuses if the dev tree is dirty in target dirs.
# Skip rather than false-fail when run on a dirty working tree (mirrors how the
# runner itself guards), so a developer mid-edit isn't blocked.
_dirty="$( { git -C "$REPO_ROOT" diff --name-only -- core plugins scripts tests
             git -C "$REPO_ROOT" ls-files --others --exclude-standard -- core plugins scripts tests
           } 2>/dev/null )"
if [[ -n "$_dirty" ]]; then
    print_test_section "SKIP — working tree dirty in mutation-target dirs"
    assert_pass "skipped: cannot exercise runner on a dirty tree (commit/stash first)"
    cleanup_test_env
    print_test_results
fi

# ─── Build a fixture mutation dir ────────────────────────────────────────────
# File/Expected-failing-test reference a real linked pair so the relevance gate
# (#309) passes; the actual Patch/Test operate inside the throwaway worktree.
FIXDIR="$TEST_TEMP_DIR/mutation"
mkdir -p "$FIXDIR"

# (a) CAUGHT: patch writes a marker file into the worktree (dirties it), the
#     test asserts content that is NOT present → non-zero → mutation caught.
cat > "$FIXDIR/01-caught.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Mutation
Synthetic caught mutation: write a sentinel into the worktree; the test
demands a token the sentinel lacks, so it fails (mutation is caught).

## Patch
```bash
printf 'MUTATED\n' > scripts/_zb_mut_fixture_caught.sh
```

## Expected failing test
`tests/unit/mutation-relevance-test.sh` — references run-mutation.sh.

## Result
Caught: the test greps for HEALTHY in a file that contains MUTATED.

## Test
```bash
grep -q HEALTHY scripts/_zb_mut_fixture_caught.sh
```
EOF

# (b) STRUCTURAL FAIL: missing the required "## Mutation" section.
cat > "$FIXDIR/02-structural.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Expected failing test
`tests/unit/mutation-relevance-test.sh`

## Patch
```bash
true
```

## Result
N/A

## Test
```bash
true
```
EOF

# (c) NO-OP PATCH: a patch that touches no tracked target files in the worktree.
cat > "$FIXDIR/03-noop.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Mutation
Synthetic no-op: the patch does nothing, so the worktree stays clean and the
runner must report a no-op patch (sed/awk no-op guard).

## Patch
```bash
true
```

## Expected failing test
`tests/unit/mutation-relevance-test.sh`

## Result
No-op.

## Test
```bash
true
```
EOF

_run_fixture() {
    # $1 = jobs value; $2 = out file; extra env via caller. Returns runner rc.
    local jobs="$1" out="$2"
    set +e
    ZBUILD_MUTATION_DIR="$FIXDIR" \
    ZBUILD_MUTATION_PARALLEL_JOBS="$jobs" \
        bash "$RUNNER" > "$out" 2>/dev/null
    local rc=$?
    set -e
    printf '%s' "$rc"
}

# ─── Test 1: serial≡parallel byte-identical (stdout + rc) ────────────────────
print_test_section "1. serial (jobs=1) ≡ parallel (jobs=4): stdout + rc byte-identical"
SER_OUT="$TEST_TEMP_DIR/serial.out"
PAR_OUT="$TEST_TEMP_DIR/parallel.out"
ser_rc="$(_run_fixture 1 "$SER_OUT")"
par_rc="$(_run_fixture 4 "$PAR_OUT")"

# True byte-for-byte comparison via cmp — `assert_eq "$(cat …)" …` would strip
# trailing newlines in command substitution and mask a real difference.
if cmp -s "$SER_OUT" "$PAR_OUT"; then
    assert_pass "serial and parallel stdout are byte-identical"
else
    assert_fail "serial and parallel stdout are byte-identical" "$(diff "$SER_OUT" "$PAR_OUT" | head -20)"
fi
assert_eq "serial and parallel exit codes match" "$ser_rc" "$par_rc"
assert_contains "output carries the mutation: P/T passed line" "$(cat "$SER_OUT")" "mutation: 1/3 passed"
assert_contains "caught fixture is accounted PASS" "$(cat "$SER_OUT")" "PASS  01-caught.md  (caught: rc="
assert_contains "structural fixture is accounted FAIL" "$(cat "$SER_OUT")" "FAIL  02-structural.md  (structural)"
assert_contains "no-op fixture is accounted FAIL" "$(cat "$SER_OUT")" "FAIL  03-noop.md  (no-op patch)"

# ─── Test 2: no stray worktrees left behind ──────────────────────────────────
print_test_section "2. parallel run leaves no stray worktrees"
wt_before="$(git -C "$REPO_ROOT" worktree list | wc -l | tr -d ' ')"
_run_fixture 4 "$TEST_TEMP_DIR/wt-probe.out" >/dev/null
wt_after="$(git -C "$REPO_ROOT" worktree list | wc -l | tr -d ' ')"
assert_eq "worktree count unchanged across a parallel run" "$wt_before" "$wt_after"

stray="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | grep -c 'zb-mut\.' || true)"
assert_eq "no zb-mut. worktree path remains registered" "0" "$stray"

# ─── Test 3: stdin-EOF + timeout guard ───────────────────────────────────────
print_test_section "3. read-blocked test gets EOF; sleeping test is time-bounded"
TIMEDIR="$TEST_TEMP_DIR/mutation-timeout"
mkdir -p "$TIMEDIR"

# Install an ENFORCING gtimeout shim at the front of PATH ($TEST_TEMP_DIR/bin is
# already first — test-helpers.sh:88) so this test deterministically exercises
# the runner's timeout path even on hosts lacking real GNU timeout, where
# setup_test_env installs a NON-enforcing `timeout` stub the runner would
# otherwise pick up. run-mutation.sh probes gtimeout first, so this shim wins.
cat > "$TEST_TEMP_DIR/bin/gtimeout" <<'SHIM'
#!/usr/bin/env bash
_dur="$1"; shift
"$@" &
_cmd=$!
( sleep "$_dur"; kill -KILL "$_cmd" 2>/dev/null ) &
_watch=$!
wait "$_cmd" 2>/dev/null; _rc=$?
kill "$_watch" 2>/dev/null; wait "$_watch" 2>/dev/null || true
exit "$_rc"
SHIM
chmod +x "$TEST_TEMP_DIR/bin/gtimeout"

# A test that reads stdin must terminate via </dev/null EOF and be accounted.
cat > "$TIMEDIR/01-stdin.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Mutation
Synthetic: dirty the worktree, then a test that blocks on stdin — must get EOF.

## Patch
```bash
printf 'x\n' > scripts/_zb_mut_fixture_stdin.sh
```

## Expected failing test
`tests/unit/mutation-relevance-test.sh`

## Result
Caught after EOF: read returns non-zero at end-of-input (the test's exit
status is read's, so a blocked-then-EOF read is accounted as caught).

## Test
```bash
read -r _line
```
EOF

# A test that sleeps longer than the bound must be killed (rc 124 → caught) and
# the run must finish promptly.
cat > "$TIMEDIR/02-sleep.md" <<'EOF'
## File
`scripts/run-mutation.sh`

## Mutation
Synthetic: dirty the worktree, then a test that sleeps past the timeout.

## Patch
```bash
printf 'x\n' > scripts/_zb_mut_fixture_sleep.sh
```

## Expected failing test
`tests/unit/mutation-relevance-test.sh`

## Result
Caught: the sleep is killed by the per-mutant timeout (rc 124).

## Test
```bash
sleep 5
```
EOF

TIMEOUT_OUT="$TEST_TEMP_DIR/timeout.out"
_t_start="$(date +%s)"
set +e
ZBUILD_MUTATION_DIR="$TIMEDIR" \
ZBUILD_MUTATION_PARALLEL_JOBS=4 \
ZBUILD_MUTATION_TEST_TIMEOUT=1 \
    bash "$RUNNER" > "$TIMEOUT_OUT" 2>/dev/null
_timeout_rc=$?
set -e
_t_end="$(date +%s)"
_elapsed=$(( _t_end - _t_start ))

# Both fixtures must be CAUGHT: the stdin-reader fails on EOF (</dev/null) and
# the sleeper is killed by the 1s timeout (rc 124). On a full pass the runner
# emits only the count line (the results table is failure-only), so the caught
# evidence is the 2/2 line + rc 0 — not per-spec PASS strings.
assert_contains "stdin + sleep fixtures both caught (full pass)" \
    "$(cat "$TIMEOUT_OUT")" "mutation: 2/2 passed"
assert_eq "timeout-guarded run exits 0 (all caught)" "0" "$_timeout_rc"
# 1s bound × 2 mutants must finish far under the would-be 10s serial sleep —
# proves the per-mutant timeout actually killed the sleeper.
if [[ "$_elapsed" -lt 10 ]]; then
    assert_pass "run finished promptly (${_elapsed}s) — timeout enforced"
else
    assert_fail "run finished promptly — timeout enforced" "elapsed=${_elapsed}s"
fi

cleanup_test_env
print_test_results
