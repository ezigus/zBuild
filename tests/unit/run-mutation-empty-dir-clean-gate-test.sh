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

# run-mutation.sh derives both $job_dir and its worktrees from ${TMPDIR:-/tmp}.
# Pin it per-test: the leak probe below counts zb-mut-jobs.* dirs, and scanning
# the host-wide tmp would both couple this test to whatever else is running and
# flake under the parallel tier runner, where a real mutation tier legitimately
# has one open.
MUT_TMP="$TEST_TEMP_DIR/mut-tmp"
mkdir -p "$MUT_TMP"

_MUT_OUT="" _MUT_ERR="" _MUT_RC=0
_run_mut() {
    local dir="$1"
    _MUT_OUT="" _MUT_ERR="" _MUT_RC=0
    TMPDIR="$MUT_TMP" ZBUILD_MUTATION_DIR="$dir" ZBUILD_MUTATION_PARALLEL_JOBS=1 \
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

# The ABORTED line must not match either aggregator marker contract, so no
# consumer can miscount it as a tier result or as a failing test file.
#
# Both patterns are read from the REAL sources at run time rather than copied
# here. A copy asserts only that this file agrees with itself: whoever later
# widens the aggregator regex gets a green test and a silently miscounted tier —
# the green-but-inert class ADR-036 exists to catch. Reading the live definitions
# means the assertion moves when the contract moves.
_ABORTED_LINE=""
while IFS= read -r _ln; do
    [[ "$_ln" == *ABORTED* ]] && _ABORTED_LINE="$_ln" && break
done <<< "$_MUT_OUT"
[[ -n "$_ABORTED_LINE" ]] \
    && assert_pass "[SPEC-2] an ABORTED line was actually captured" \
    || assert_fail "[SPEC-2] an ABORTED line was actually captured" "none found"

# (a) The tier-summary aggregator in scripts/run-tests.sh. The regex lives
# inside a `[[ =~ ]]` test; pull the literal out by content, never by line
# number, and unescape the `\ ` that bash's =~ syntax requires.
_AGG_SRC_LINE="$(grep -m1 -F 'passed(\ \(([0-9]+)\ skipped\))?' "$REPO_ROOT/scripts/run-tests.sh")"
_AGG_RE="${_AGG_SRC_LINE#*=~ }"
_AGG_RE="${_AGG_RE%% ]]*}"
_AGG_RE="${_AGG_RE//\\ / }"
[[ -n "$_AGG_RE" ]] \
    && assert_pass "[SPEC-2] aggregator regex extracted from run-tests.sh (not a copy)" \
    || assert_fail "[SPEC-2] aggregator regex extracted from run-tests.sh (not a copy)" "empty"
if grep -qE "$_AGG_RE" <<< "$_ABORTED_LINE"; then
    assert_fail "[SPEC-2] ABORTED line must not match the live tier-summary regex" \
        "re: $_AGG_RE / line: $_ABORTED_LINE"
else
    assert_pass "[SPEC-2] ABORTED line does not match the live tier-summary regex"
fi

# (b) _TEST_FAIL_MARKER_RE — the red set that drives targeted rerun. It is a
# plain assignment in parse.sh, so read it straight from the file (sourcing
# parse.sh would pull in the whole pattern bank).
_FAIL_RE_SRC="$(grep -m1 '^_TEST_FAIL_MARKER_RE=' "$REPO_ROOT/plugins/tool/test/lib/parse.sh")"
_FAIL_RE="${_FAIL_RE_SRC#*=}"
_FAIL_RE="${_FAIL_RE#\'}"; _FAIL_RE="${_FAIL_RE%\'}"
[[ -n "$_FAIL_RE" ]] \
    && assert_pass "[SPEC-2] _TEST_FAIL_MARKER_RE extracted from parse.sh (not a copy)" \
    || assert_fail "[SPEC-2] _TEST_FAIL_MARKER_RE extracted from parse.sh (not a copy)" "empty"
if grep -qE "$_FAIL_RE" <<< "$_ABORTED_LINE"; then
    assert_fail "[SPEC-2] ABORTED line must not match the live fail-marker regex" \
        "re: $_FAIL_RE / line: $_ABORTED_LINE"
else
    assert_pass "[SPEC-2] ABORTED line does not match the live fail-marker regex"
fi

# Both extractions must be live patterns, not empty strings that would make the
# two negative assertions above vacuous.
if grep -qE "$_AGG_RE" <<< "mutation: 0/0 passed"; then
    assert_pass "[SPEC-2] extracted aggregator regex is live (matches a real summary line)"
else
    assert_fail "[SPEC-2] extracted aggregator regex failed to match a known-good summary" \
        "re: $_AGG_RE"
fi
if grep -qE "$_FAIL_RE" <<< "unit: FAIL tests/unit/x-test.sh"; then
    assert_pass "[SPEC-2] extracted fail-marker regex is live (matches a real FAIL line)"
else
    assert_fail "[SPEC-2] extracted fail-marker regex failed to match a known-good FAIL line" \
        "re: $_FAIL_RE"
fi

# ── job_dir must not leak on the abort path ─────────────────────────────────
# The clean-tree check now runs AFTER `mktemp -d` creates $job_dir, so the abort
# path exits with a temp dir already allocated. _mut_teardown removes it via the
# EXIT trap; assert that mechanically rather than by reading the trap. $MUT_TMP
# is this test's own tmp root, so the count is exact — no host-wide scan, and
# nothing another tier is doing concurrently can appear in it.
_JOBDIRS_AFTER="$(find "$MUT_TMP" -maxdepth 1 -name 'zb-mut-jobs.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2] abort path leaves no zb-mut-jobs.* temp dir behind" "0" "$_JOBDIRS_AFTER"
# A count of 0 is only meaningful while job_dir is still built from $TMPDIR under
# that name — otherwise the probe above passes by looking in the wrong place.
assert_contains "[SPEC-2] job_dir is still derived from \$TMPDIR (keeps the leak probe honest)" \
    "$(grep -F 'job_dir="$(mktemp -d' "$RUN_SCRIPT")" 'TMPDIR:-/tmp}/zb-mut-jobs'

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

# ── Case 4b: SPEC_MUT really does count as n_specs > 0 ──────────────────────
# Case 2 only proves the gate fires for SPEC_MUT; it cannot distinguish "the
# gate fired because specs were counted" from "the gate fired for some other
# reason". The fixture is a STRUCTURALLY-INVALID spec, and today Phase A
# increments idx before every structural `continue` — so it counts. If that
# ordering ever changes, n_specs would silently drop to 0, the gate would be
# bypassed, and Case 2 would fail with a confusing exit-code mismatch rather
# than naming the cause. This run is clean, so the tier summary is reached:
# a counted spec yields a non-zero denominator.
[[ -n "$(grep -oE 'mutation: [0-9]+/[1-9][0-9]* passed' <<< "$_MUT_OUT")" ]] \
    && assert_pass "SPEC_MUT counts toward n_specs (Phase A counts invalid specs too — Case 2 depends on it)" \
    || assert_fail "SPEC_MUT counts toward n_specs (Phase A counts invalid specs too)" "denominator was 0: $_MUT_OUT"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
