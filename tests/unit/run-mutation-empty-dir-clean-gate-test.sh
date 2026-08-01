#!/usr/bin/env bash
# Tests: scripts/run-mutation.sh — clean-tree gate fires only when specs exist (#1661)
# SPEC-1 CHANGE  dirty tree + empty mutation dir → exit 0, mutation: 0/0 passed
# SPEC-2 CHANGE  dirty tree + non-empty mutation dir → exit 1, ABORTED on stdout
# SPEC-3 GUARD   clean tree (empty or non-empty dir) → no ABORTED, normal behavior
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

print_test_header "run-mutation.sh clean-tree gate gated on spec count (#1661)"
setup_test_env "run-mutation-empty-dir-clean-gate"

# Git sandbox: copy run-mutation.sh to sandbox/scripts/ so REPO_ROOT = sandbox.
# This lets us dirty/clean core/ in isolation without touching the live worktree.
SANDBOX="$TEST_TEMP_DIR/sandbox"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/core"

REAL_GIT="$(command -v git 2>/dev/null || true)"
if [[ -z "$REAL_GIT" ]]; then
    for _g in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
        [[ -x "$_g" ]] && REAL_GIT="$_g" && break
    done
fi

cp "$REPO_ROOT/scripts/run-mutation.sh" "$SANDBOX/scripts/run-mutation.sh"
(
    cd "$SANDBOX"
    "$REAL_GIT" init -q -b main 2>/dev/null || "$REAL_GIT" init -q
    "$REAL_GIT" config user.email "test@zbuild.local"
    "$REAL_GIT" config user.name "zbuild-test"
    "$REAL_GIT" config commit.gpgsign false
    echo "initial" > core/dummy.sh
    "$REAL_GIT" add core/dummy.sh scripts/run-mutation.sh
    "$REAL_GIT" commit -q -m "seed"
) >/dev/null 2>&1

RUN_SCRIPT="$SANDBOX/scripts/run-mutation.sh"
EMPTY_MUT="$TEST_TEMP_DIR/empty-mut"
SPEC_MUT="$TEST_TEMP_DIR/spec-mut"
mkdir -p "$EMPTY_MUT" "$SPEC_MUT"

# Structurally-invalid spec (missing all required sections): fails at the
# structural gate in Phase A so no worktree operations are ever attempted.
cat > "$SPEC_MUT/test-spec.md" <<'EOF'
# Not a valid mutation spec — no required sections
EOF

_MUT_OUT="" _MUT_ERR="" _MUT_RC=0
_run_mut() {
    local dir="$1"
    _MUT_OUT="" _MUT_ERR="" _MUT_RC=0
    ZBUILD_MUTATION_DIR="$dir" ZBUILD_MUTATION_PARALLEL_JOBS=1 \
        bash "$RUN_SCRIPT" \
        >"$TEST_TEMP_DIR/_mut.out" 2>"$TEST_TEMP_DIR/_mut.err" || _MUT_RC=$?
    _MUT_OUT="$(cat "$TEST_TEMP_DIR/_mut.out")"
    _MUT_ERR="$(cat "$TEST_TEMP_DIR/_mut.err")"
}

_make_dirty() { echo "dirty" >> "$SANDBOX/core/dummy.sh"; }
_make_clean() {
    (cd "$SANDBOX" && "$REAL_GIT" checkout -- core/dummy.sh >/dev/null 2>&1 || true)
}

# ── Case 1 [SPEC-1]: dirty tree + empty mutation dir ────────────────────────
# Before the fix, _assert_clean_targets fired unconditionally → exit 1 even
# with an empty dir. After the fix, n_specs=0 gates the check → exit 0.
_make_dirty
_run_mut "$EMPTY_MUT"
assert_eq "[SPEC-1] dirty tree + empty dir → exit 0" "0" "$_MUT_RC"
assert_contains "[SPEC-1] dirty tree + empty dir → 'mutation: 0/0 passed'" \
    "$_MUT_OUT" "mutation: 0/0 passed"

# ── Case 2 [SPEC-2]: dirty tree + non-empty mutation dir ────────────────────
# n_specs > 0 → _assert_clean_targets fires → ABORTED emitted to stdout, exit 1.
_run_mut "$SPEC_MUT"
assert_eq "[SPEC-2] dirty tree + non-empty dir → exit 1" "1" "$_MUT_RC"
assert_contains "[SPEC-2] stderr contains 'refusing'" "$_MUT_ERR" "refusing"
assert_contains "[SPEC-2] stdout contains ABORTED line" "$_MUT_OUT" "ABORTED"

# The ABORTED line must not match either aggregator marker regex so the
# run-tests.sh concurrent-output parser never confuses it for a tier result.
_ABORTED_LINE=""
while IFS= read -r _ln; do
    [[ "$_ln" == *ABORTED* ]] && _ABORTED_LINE="$_ln" && break
done <<< "$_MUT_OUT"
if ! grep -qE '^[A-Za-z][A-Za-z0-9_-]*: [0-9]+/[0-9]+ passed' <<< "$_ABORTED_LINE"; then
    assert_pass "[SPEC-2] ABORTED line does not match passed-count regex"
else
    assert_fail "[SPEC-2] ABORTED line must not match passed-count regex" \
        "line: $_ABORTED_LINE"
fi
if ! grep -qE '^[A-Za-z][A-Za-z0-9_-]*: (FAIL|TIMEOUT) ' <<< "$_ABORTED_LINE"; then
    assert_pass "[SPEC-2] ABORTED line does not match FAIL/TIMEOUT marker regex"
else
    assert_fail "[SPEC-2] ABORTED line must not match FAIL/TIMEOUT marker regex" \
        "line: $_ABORTED_LINE"
fi

# ── Case 3 [SPEC-3]: clean tree + empty mutation dir ────────────────────────
_make_clean
_run_mut "$EMPTY_MUT"
assert_eq "[SPEC-3] clean tree + empty dir → exit 0" "0" "$_MUT_RC"
assert_contains "[SPEC-3] clean tree + empty dir → 'mutation: 0/0 passed'" \
    "$_MUT_OUT" "mutation: 0/0 passed"

# ── Case 4 [SPEC-3]: clean tree + non-empty mutation dir ────────────────────
# Clean tree → _assert_clean_targets passes → script proceeds normally (spec
# fails at structural gate). ABORTED must be absent from stdout.
_run_mut "$SPEC_MUT"
if ! grep -q "ABORTED" <<< "$_MUT_OUT"; then
    assert_pass "[SPEC-3] clean tree + non-empty dir → ABORTED absent from stdout"
else
    assert_fail "[SPEC-3] ABORTED must not appear when tree is clean" \
        "stdout: $_MUT_OUT"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
