#!/usr/bin/env bash
# Tests: scripts/run-mutation.sh — a mutant's test that ignores TERM cannot hang
# the tier: the per-mutant timeout follows TERM with KILL, as run-tests.sh does.
#
# Found on #1850 (2026-10-08): the full suite ran 8h57m. Under a mutant of
# run-status-comment.md, runner-status-comment-hook-test.sh left a child that
# runs `trap "" TERM` on purpose (its SPEC-5). The per-mutant `gtimeout 300`
# sent TERM at 300s and never sent KILL, so the child — and the tier, and the
# suite — waited until it was killed by hand.
#
# SPEC-1  a mutant whose test ignores TERM ends within the bound (timeout + kill
#         grace), the tier ends, and nothing of that test is left running.
set -uo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-mutation.sh — a mutant test that ignores TERM cannot hang the tier"
setup_test_env "run-mutation-kill-grace"

TOUT=""
for _t in gtimeout timeout; do command -v "$_t" >/dev/null 2>&1 && { TOUT="$_t"; break; }; done
if [[ -z "$TOUT" ]]; then
    assert_pass "[setup] skipped: no timeout/gtimeout binary on this machine"
    cleanup_test_env; print_test_results; exit 0
fi
REAL_GIT=""
for _g in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
    [[ -x "$_g" ]] && { REAL_GIT="$_g"; break; }
done
[[ -n "$REAL_GIT" ]] || REAL_GIT="$(command -v git)"

# A sandbox repo: run-mutation.sh resolves its repo from its own location, so a
# copy under sandbox/scripts/ runs every worktree against the sandbox only.
SANDBOX="$TEST_TEMP_DIR/sandbox"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/core" "$SANDBOX/tests/mutation"
cp "$REPO_ROOT/scripts/run-mutation.sh" "$SANDBOX/scripts/run-mutation.sh"
printf 'widget_ok() {\n    return 0\n}\n' > "$SANDBOX/core/widget.sh"
mkdir -p "$SANDBOX/tests/unit"
printf 'source core/widget.sh\nwidget_ok\n' > "$SANDBOX/tests/unit/widget-test.sh"
# A name unique to this run, so the leftover check can find exactly this child.
MARK="zbkillgrace$$x"
{
    printf '## File\n`core/widget.sh` — widget_ok.\n\n'
    printf '## Mutation\nFlip widget_ok'"'"'s return.\n\n'
    printf '## Patch\n```bash\n'
    printf "sed -i.bak 's/return 0/return 1/' core/widget.sh && rm -f core/widget.sh.bak\n"
    printf '```\n\n'
    printf '## Expected failing test\n`tests/unit/widget-test.sh` — stands in for a test that ignores TERM.\n\n'
    printf '## Result\nCaught by the timeout.\n\n'
    printf '## Test\n```bash\n'
    printf 'trap "" TERM; bash -c '"'"'trap "" TERM; exec -a %s sleep 600'"'"' & wait\n' "$MARK"
    printf '```\n'
} > "$SANDBOX/tests/mutation/stubborn.md"
(
    cd "$SANDBOX" || exit 1
    "$REAL_GIT" init -q
    "$REAL_GIT" config user.email "test@zbuild.local"
    "$REAL_GIT" config user.name "zbuild-test"
    "$REAL_GIT" config commit.gpgsign false
    "$REAL_GIT" add -A
    "$REAL_GIT" commit -q -m seed
) >/dev/null 2>&1

print_test_section "SPEC-1: TERM is followed by KILL"
t0=$(date +%s)
rc=0
( cd "$SANDBOX" || exit 1
  ZBUILD_MUTATION_TEST_TIMEOUT=2 ZBUILD_MUTATION_KILL_GRACE=2 ZBUILD_MUTATION_PARALLEL_JOBS=1 \
      "$TOUT" -k 5 60 bash scripts/run-mutation.sh ) >"$TEST_TEMP_DIR/out.txt" 2>&1 || rc=$?
t1=$(date +%s)
_out="$(cat "$TEST_TEMP_DIR/out.txt" 2>/dev/null)"
# Premises: the mutant really ran its test (not refused before it), and the
# per-mutant timeout really fired (the test cannot end on its own).
assert_not_contains_s() { if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi; }
assert_not_contains_s "[setup] the mutant's spec was accepted and its test run" "$_out" "unparseable"
assert_contains "[setup] ...and the tier scored that one mutant" "$_out" "mutation: 1/1"
if [[ $(( t1 - t0 )) -ge 2 ]]; then
    assert_pass "[setup] the run lasted at least the 2s timeout ($(( t1 - t0 ))s)"
else
    assert_fail "[setup] the run lasted at least the 2s timeout" "only $(( t1 - t0 ))s — the test never ran"
fi
if [[ "$rc" -ne 124 && "$rc" -ne 137 && $(( t1 - t0 )) -lt 40 ]]; then
    assert_pass "[SPEC-1] the tier ends within the bound ($(( t1 - t0 ))s)"
else
    assert_fail "[SPEC-1] the tier ends within the bound" \
        "rc=$rc after $(( t1 - t0 ))s — the mutant's test was never killed"
fi
_left="$(pgrep -f "$MARK" 2>/dev/null || true)"
assert_eq "[SPEC-1] nothing of the mutant's test is left running" "" "$_left"
if [[ -n "$_left" ]]; then
    # shellcheck disable=SC2086  # a list of pids
    kill -KILL $_left 2>/dev/null || true
fi

cleanup_test_env
print_test_results
