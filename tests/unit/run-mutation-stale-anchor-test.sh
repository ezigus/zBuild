#!/usr/bin/env bash
# Tests: scripts/run-mutation.sh — a spec whose patch anchor is gone is a
# FAILURE, not transient contention (#2086, ADR-012 "Outcome classification").
#
# memory.md printed `INFRA (patch failed after retries)` on every run for weeks
# while its anchor no longer existed in core/memory/contract.sh; the tier still
# read 23/23 passed. A patch that also fails when re-applied alone, serially, to
# a clean checkout can never apply — that is a stale spec. A patch that applies
# on that serial re-apply only lost a race, and stays non-fatal.
#
# SPEC-1  anchor gone → `STALE <spec>` row naming the anchor, counted in the
#         score, `mutation-stale:` summary line, exit 1, no INFRA row.
# SPEC-2  patch fails once then applies on the serial re-apply → INFRA,
#         excluded from the score, exit 0 (today's #1184 handling).
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC2034
SCRIPT_DIR="$TEST_SCRIPT_DIR"
REPO_ROOT="$TEST_REPO_ROOT"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-mutation.sh — a gone anchor fails the tier; contention does not (#2086)"
setup_test_env "run-mutation-stale-anchor"

REAL_GIT=""
for _g in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
    [[ -x "$_g" ]] && REAL_GIT="$_g" && break
done
[[ -n "$REAL_GIT" ]] || REAL_GIT="$(command -v git)"

# Sandbox repo: run-mutation.sh resolves REPO_ROOT from its own location, so a
# copy under sandbox/scripts/ runs every worktree against the sandbox only.
SANDBOX="$TEST_TEMP_DIR/sandbox"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/core" "$SANDBOX/tests/unit"
cp "$REPO_ROOT/scripts/run-mutation.sh" "$SANDBOX/scripts/run-mutation.sh"
printf 'widget_ok() {\n    return 0\n}\n' > "$SANDBOX/core/widget.sh"
printf 'source core/widget.sh\nwidget_ok\n' > "$SANDBOX/tests/unit/widget-test.sh"
(
    cd "$SANDBOX"
    "$REAL_GIT" init -q
    "$REAL_GIT" config user.email "test@zbuild.local"
    "$REAL_GIT" config user.name "zbuild-test"
    "$REAL_GIT" config commit.gpgsign false
    "$REAL_GIT" add -A
    "$REAL_GIT" commit -q -m seed
) >/dev/null 2>&1

MUT_TMP="$TEST_TEMP_DIR/mut-tmp"
mkdir -p "$MUT_TMP"

_write_spec() {
    local path="$1" patch="$2"
    cat > "$path" <<EOF
## File
\`core/widget.sh\` — widget_ok.

## Mutation
Flip widget_ok's return.

## Patch
\`\`\`bash
$patch
\`\`\`

## Expected failing test
\`tests/unit/widget-test.sh\` — calls widget_ok.

## Result
Caught.

## Test
\`\`\`bash
bash tests/unit/widget-test.sh
\`\`\`
EOF
}

_MUT_OUT="" _MUT_RC=0
_run_mut() {
    _MUT_RC=0
    TMPDIR="$MUT_TMP" ZBUILD_MUTATION_DIR="$1" ZBUILD_MUTATION_PARALLEL_JOBS=2 \
    ZB_TRANSIENT_MARK="$TEST_TEMP_DIR/transient.mark" \
        bash "$SANDBOX/scripts/run-mutation.sh" \
        >"$TEST_TEMP_DIR/_mut.out" 2>"$TEST_TEMP_DIR/_mut.err" || _MUT_RC=$?
    _MUT_OUT="$(cat "$TEST_TEMP_DIR/_mut.out")"
}

# The anchor this patch asserts on was never in core/widget.sh: every apply, on
# any checkout, fails the same way — exactly memory.md's failure.
STALE_PATCH='grep -qF "GONE_ANCHOR_2086" core/widget.sh || { echo "patch target not found: GONE_ANCHOR_2086" >&2; exit 1; }
sed -i.bak "s/return 0/return 1/" core/widget.sh && rm -f core/widget.sh.bak'
# Fails the first time only (a marker outside the worktree records the attempt),
# then applies cleanly: the shape of a lost worktree race.
# The patch shell expands $ZB_TRANSIENT_MARK, not this one.
# shellcheck disable=SC2016
TRANSIENT_PATCH='if [[ ! -e "$ZB_TRANSIENT_MARK" ]]; then : > "$ZB_TRANSIENT_MARK"; exit 1; fi
sed -i.bak "s/return 0/return 1/" core/widget.sh && rm -f core/widget.sh.bak'

# ── SPEC-1: anchor gone ─────────────────────────────────────────────────────
STALE_DIR="$TEST_TEMP_DIR/stale"
mkdir -p "$STALE_DIR"
_write_spec "$STALE_DIR/gone.md" "$STALE_PATCH"
_write_spec "$STALE_DIR/good.md" 'sed -i.bak "s/return 0/return 1/" core/widget.sh && rm -f core/widget.sh.bak'
_run_mut "$STALE_DIR"

assert_eq "[SPEC-1] a spec whose anchor is gone fails the tier (exit 1)" "1" "$_MUT_RC"
assert_contains "[SPEC-1] the gone-anchor spec gets its own STALE row" "$_MUT_OUT" "STALE gone.md"
assert_contains "[SPEC-1] the STALE row names the missing anchor" "$_MUT_OUT" "GONE_ANCHOR_2086"
assert_contains "[SPEC-1] the summary surfaces stale specs on their own line" "$_MUT_OUT" "mutation-stale: 1"
assert_contains "[SPEC-1] the stale spec counts in the score (1/2, not 1/1)" "$_MUT_OUT" "mutation: 1/2 passed"
if grep -qF "INFRA gone.md" <<< "$_MUT_OUT"; then
    assert_fail "[SPEC-1] a gone anchor is not filed as INFRA contention" "$_MUT_OUT"
else
    assert_pass "[SPEC-1] a gone anchor is not filed as INFRA contention"
fi

# ── SPEC-2: transient contention stays non-fatal ────────────────────────────
TRANS_DIR="$TEST_TEMP_DIR/transient"
mkdir -p "$TRANS_DIR"
_write_spec "$TRANS_DIR/racy.md" "$TRANSIENT_PATCH"
_run_mut "$TRANS_DIR"

assert_file_exists "[SPEC-2] the racy patch really did fail once (marker written)" "$TEST_TEMP_DIR/transient.mark"
assert_eq "[SPEC-2] contention does not fail the tier (exit 0)" "0" "$_MUT_RC"
assert_contains "[SPEC-2] contention keeps its INFRA row" "$_MUT_OUT" "INFRA racy.md"
assert_contains "[SPEC-2] contention stays out of the score" "$_MUT_OUT" "mutation: 0/0 passed"
if grep -qF "mutation-stale:" <<< "$_MUT_OUT"; then
    assert_fail "[SPEC-2] contention is not reported as stale" "$_MUT_OUT"
else
    assert_pass "[SPEC-2] contention is not reported as stale"
fi

# Every worktree the runner made in the sandbox is gone.
_left="$("$REAL_GIT" -C "$SANDBOX" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"  # sigpipe-ok: grep -c reads all input
assert_eq "no mutant worktree left behind" "1" "$_left"

cleanup_test_env
print_test_results
