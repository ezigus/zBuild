#!/usr/bin/env bash
# Tests: scripts/run-mutation.sh — a run's teardown removes only the worktrees it
# owns (#2230).
#
# Why: the EXIT teardown removed EVERY zb-mut.* worktree registered in the repo.
# `npm test` runs the mutation tier alongside the integration tier, and several
# integration tests run run-mutation.sh themselves — so whichever run finished
# first deleted the other's live mutant worktrees. A caught mutant whose tree
# vanished scored FAIL ("no-op patch", or a test run in a deleted cwd), and
# mutation-infra-nonfatal-test.sh failed only inside a full suite. Two pipeline
# runs against one repo hit the same hole.
#
# O1 [change] a run that finishes and tears down leaves another run's live
#             mutant worktree alone — the held mutant still scores as caught
# O2 [guard]  a leftover worktree from a run that is no longer alive is still
#             swept (#992's cleanup is kept, scoped to dead owners)
# O3 [change] a run owned by ANOTHER USER is alive too: `kill -0` fails on it
#             (EPERM) exactly as on a dead pid, so its worktree was swept (review)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/run-mutation.sh — teardown removes only its own worktrees (#2230)"
setup_test_env "mutation-teardown-ownership"

# Everything runs in a throwaway clone carrying THIS tree's runner, so the real
# repo's worktree registry is never touched (and a dirty dev tree needs no skip).
CLONE="$TEST_TEMP_DIR/clone"
git clone -q --shared "$REPO_ROOT" "$CLONE"
git -C "$CLONE" config user.email t@t
git -C "$CLONE" config user.name t
cp "$REPO_ROOT/scripts/run-mutation.sh" "$CLONE/scripts/run-mutation.sh"
git -C "$CLONE" commit -qam "runner under test" --allow-empty
RUNNER="$CLONE/scripts/run-mutation.sh"
# _registered <basename> — 0 when a worktree of that name is registered in the clone.
_registered() {
    local list; list="$(git -C "$CLONE" worktree list --porcelain 2>/dev/null)"
    grep -qF "$1" <<< "$list"
}

READY="$TEST_TEMP_DIR/held-ready"
GO="$TEST_TEMP_DIR/held-go"

# _spec <file> <patch> <test> — a minimal mutation spec aimed at run-mutation.sh.
_spec() {
    cat > "$1" <<EOF
## File
\`scripts/run-mutation.sh\`

## Mutation
Synthetic mutant for the teardown-ownership test.

## Patch
\`\`\`bash
$2
\`\`\`

## Expected failing test
\`tests/unit/mutation-relevance-test.sh\` — references run-mutation.sh.

## Result
Caught.

## Test
\`\`\`bash
$3
\`\`\`
EOF
}

# Run A's mutant announces itself, then holds until GO. If its worktree was
# removed meanwhile, the mutated file is gone and the test exits 0 — the runner
# scores that as a slipped mutant (FAIL). Intact, the grep fails → caught.
A_DIR="$TEST_TEMP_DIR/run-a"; mkdir -p "$A_DIR"
_spec "$A_DIR/01-held.md" \
    "printf 'MUTATED\\n' > scripts/_zb_mut_owned_a.sh" \
    "touch '$READY'; for _i in \$(seq 1 400); do [[ -e '$GO' ]] && break; sleep 0.05; done; [[ -f scripts/_zb_mut_owned_a.sh ]] || exit 0; grep -q HEALTHY scripts/_zb_mut_owned_a.sh"

B_DIR="$TEST_TEMP_DIR/run-b"; mkdir -p "$B_DIR"
_spec "$B_DIR/01-quick.md" \
    "printf 'MUTATED\\n' > scripts/_zb_mut_owned_b.sh" \
    "grep -q HEALTHY scripts/_zb_mut_owned_b.sh"

print_test_section "O1: another run's teardown leaves a live mutant alone"
A_OUT="$TEST_TEMP_DIR/a.out"
ZBUILD_MUTATION_DIR="$A_DIR" ZBUILD_MUTATION_PARALLEL_JOBS=1 bash "$RUNNER" > "$A_OUT" 2>/dev/null &
A_PID=$!
for _i in $(seq 1 400); do [[ -e "$READY" ]] && break; sleep 0.05; done
assert_file_exists "[O1] fixture: run A's mutant is live and holding" "$READY"

# Run B starts, finishes and tears down while A's mutant is still running.
ZBUILD_MUTATION_DIR="$B_DIR" ZBUILD_MUTATION_PARALLEL_JOBS=1 bash "$RUNNER" > "$TEST_TEMP_DIR/b.out" 2>/dev/null || true
assert_contains "[O1] fixture: run B completed" "$(cat "$TEST_TEMP_DIR/b.out")" "mutation: 1/1 passed"

touch "$GO"
a_rc=0; wait "$A_PID" || a_rc=$?
a_raw="$(cat "$A_OUT")"
# An all-pass run prints only its score line (the per-spec table appears on a
# fail or infra outcome), so the score is what says the mutant was caught.
assert_contains "[O1] run A's held mutant is still caught after run B's teardown" \
    "$a_raw" "mutation: 1/1 passed"
assert_eq "[O1] run A exits 0" "0" "$a_rc"

print_test_section "O2: a dead run's leftover worktree is still swept"
# A pid that cannot exist (above any pid_max), so it cannot be recycled into a
# live process mid-test the way a just-reaped child's pid can (review).
_dead=999999999
_stale="$(mktemp -d "${TMPDIR:-/tmp}/zb-mut.${_dead}.XXXXXX")"
rmdir "$_stale"
git -C "$CLONE" worktree add --detach "$_stale" HEAD >/dev/null 2>&1
if _registered "${_stale##*/}"; then
    assert_pass "[O2] fixture: a leftover worktree from a dead run is registered"
else
    assert_fail "[O2] fixture: a leftover worktree from a dead run is registered" "the fixture could not add it"
fi
ZBUILD_MUTATION_DIR="$B_DIR" ZBUILD_MUTATION_PARALLEL_JOBS=1 bash "$RUNNER" >/dev/null 2>&1 || true
if _registered "${_stale##*/}"; then
    assert_fail "[O2] a run's teardown sweeps a dead run's leftover worktree" "still registered"
else
    assert_pass "[O2] a run's teardown sweeps a dead run's leftover worktree"
fi

print_test_section "O3: a live run owned by another user is left alone"
# pid 1 is always alive and, for a non-root runner, not ours to signal — the
# EPERM case. Run as root, kill -0 succeeds and the check is still exact.
_foreign="$(mktemp -d "${TMPDIR:-/tmp}/zb-mut.1.XXXXXX")"; rmdir "$_foreign"
git -C "$CLONE" worktree add --detach "$_foreign" HEAD >/dev/null 2>&1
ZBUILD_MUTATION_DIR="$B_DIR" ZBUILD_MUTATION_PARALLEL_JOBS=1 bash "$RUNNER" >/dev/null 2>&1 || true
if _registered "${_foreign##*/}"; then
    assert_pass "[O3] another user's live run keeps its worktree"
else
    assert_fail "[O3] another user's live run keeps its worktree" "the teardown removed it"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
