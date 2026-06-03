#!/usr/bin/env bash
# Integration test (#661 / Wave 12-B):
# Multi-iter build cycle confirms diff.patch GROWS cumulatively across
# iterations rather than being overwritten per-iter. Drives the inner runner
# twice against the SAME repo with the same baseline ref, simulating the
# cycle orchestrator re-entering build for iter 2.
#
# Iter 1: agent writes file_A.txt → committed → diff.patch contains A
# Iter 2: agent writes file_B.txt → committed → diff.patch contains A AND B
#
# This is the contract the test stage's rsync+apply path depends on
# (Wave 12-C will remove its `git apply --check` step, but until then the
# cumulative shape ensures the patch represents the branch's full work).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #661: multi-iter cumulative diff.patch growth"
setup_test_env "build-test-cycle-multi-iter"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-multi-iter-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── Repo with baseline pinned to seed commit ────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m "M0 seed"
) >/dev/null

BASELINE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s' "$BASELINE" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"

# ─── Shared stubs ───────────────────────────────────────────────────────────
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 1; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    if [[ -n "${1:-}" && -n "${2:-}" && -f "$1" ]]; then
        cp -f "$1" "$2"
    fi
    return 0
}

ART="$ZBUILD_STATE_DIR/artifacts"
DIFF_PATCH="$ART/diff.patch"
SUMMARY_JSON="$ART/build-summary.json"
SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
echo "scope: file_A.txt, file_B.txt" > "$SCOPE_MANIFEST"

# ─── Iter 1: write file_A.txt ────────────────────────────────────────────────
print_test_section "Iter 1: agent writes file_A.txt"

cat > "$ART/plan.json" <<JSON
{ "title": "iter1: write A", "files": ["file_A.txt", "file_B.txt"] }
JSON

# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    echo "A content" > "$_repo/file_A.txt"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=5
    _ROUTE_LOOP_OUTPUT_TOKENS=3
    _ROUTE_LOOP_LAST_RESPONSE=$'wrote A\nCOMMIT_SUMMARY: iter1 A\nLOOP_COMPLETE'
    return 0
}

ZBUILD_CYCLE_ITER=1 \
cd "$REPO" && \
_build_stage_run_inner \
    "$SCOPE_MANIFEST" "$ART/plan.json" \
    "$DIFF_PATCH" "$SUMMARY_JSON" "$ART" \
    >/dev/null 2>&1 || true

# Snapshot iter-1 artifact state.
ITER1_DIFF="$TEST_TEMP_DIR/iter1.patch"
cp -f "$DIFF_PATCH" "$ITER1_DIFF"

if grep -q 'file_A.txt' "$ITER1_DIFF"; then
    assert_pass "iter1: diff.patch contains file_A.txt"
else
    assert_fail "iter1: diff.patch contains file_A.txt" \
        "size=$(wc -c < "$ITER1_DIFF") head=$(head -c 200 "$ITER1_DIFF")"
fi

# Avoid `git log | head` under set -e: git receives SIGPIPE → non-zero rc
# kills the test on Linux (macOS is forgiving). Read full log; grep -q
# scans for the marker.
iter1_log="$(git -C "$REPO" log --oneline 2>/dev/null || true)"
if printf '%s\n' "$iter1_log" | grep -q 'iter1 A'; then
    assert_pass "iter1: commit landed at HEAD"
else
    assert_fail "iter1: commit landed at HEAD" "log=$iter1_log"
fi

# ─── Iter 2: write file_B.txt; expect cumulative A+B ────────────────────────
print_test_section "Iter 2: agent writes file_B.txt; diff.patch must contain BOTH A + B"

cat > "$ART/plan.json" <<JSON
{ "title": "iter2: write B", "files": ["file_A.txt", "file_B.txt"] }
JSON

# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    echo "B content" > "$_repo/file_B.txt"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=5
    _ROUTE_LOOP_OUTPUT_TOKENS=3
    _ROUTE_LOOP_LAST_RESPONSE=$'wrote B\nCOMMIT_SUMMARY: iter2 B\nLOOP_COMPLETE'
    return 0
}

ZBUILD_CYCLE_ITER=2 \
cd "$REPO" && \
_build_stage_run_inner \
    "$SCOPE_MANIFEST" "$ART/plan.json" \
    "$DIFF_PATCH" "$SUMMARY_JSON" "$ART" \
    >/dev/null 2>&1 || true

ITER2_DIFF="$TEST_TEMP_DIR/iter2.patch"
cp -f "$DIFF_PATCH" "$ITER2_DIFF"

# Core invariant: iter-2 diff.patch contains BOTH file_A.txt + file_B.txt.
if grep -q 'file_A.txt' "$ITER2_DIFF" && grep -q 'file_B.txt' "$ITER2_DIFF"; then
    assert_pass "iter2: diff.patch contains BOTH file_A.txt AND file_B.txt (cumulative)"
else
    has_a="$(grep -c 'file_A.txt' "$ITER2_DIFF" || echo 0)"
    has_b="$(grep -c 'file_B.txt' "$ITER2_DIFF" || echo 0)"
    assert_fail "iter2: diff.patch contains BOTH A + B" \
        "A_lines=$has_a B_lines=$has_b"
fi

# Iter-2 diff.patch must byte-equal `git diff $BASELINE..HEAD`.
EXPECTED="$TEST_TEMP_DIR/expected.patch"
git -C "$REPO" diff "$BASELINE..HEAD" > "$EXPECTED" 2>/dev/null || true

if cmp -s "$ITER2_DIFF" "$EXPECTED"; then
    assert_pass "iter2: diff.patch byte-equals git diff \$baseline..HEAD"
else
    actual_sha="$(shasum -a 256 "$ITER2_DIFF" 2>/dev/null | cut -d' ' -f1)"
    expected_sha="$(shasum -a 256 "$EXPECTED" 2>/dev/null | cut -d' ' -f1)"
    assert_fail "iter2: diff.patch byte-equals git diff \$baseline..HEAD" \
        "actual=$actual_sha expected=$expected_sha"
fi

# Cumulative growth: iter-2 patch must be LARGER than iter-1 patch
# (it now also includes file_B.txt's hunks).
iter1_size="$(wc -c < "$ITER1_DIFF" | tr -d ' ')"
iter2_size="$(wc -c < "$ITER2_DIFF" | tr -d ' ')"
if [[ "$iter2_size" -gt "$iter1_size" ]]; then
    assert_pass "iter2: diff.patch GREW over iter1 ($iter1_size → $iter2_size bytes)"
else
    assert_fail "iter2: diff.patch GREW over iter1" \
        "iter1=$iter1_size iter2=$iter2_size"
fi

# ─── Apply-cleanly check: patch the BASELINE-state rsync, expect clean apply ─
print_test_section "Apply-check: cumulative patch applies cleanly to baseline snapshot"

SNAPSHOT="$TEST_TEMP_DIR/baseline-snapshot"
rm -rf "$SNAPSHOT"
# Clone-then-checkout-baseline gives us a git working tree pinned to the
# baseline SHA — what the test stage's rsync-from-baseline produces in prod.
set +e
git clone -q "$REPO" "$SNAPSHOT" 2>/dev/null
clone_rc=$?
( cd "$SNAPSHOT" && git -c advice.detachedHead=false checkout -q "$BASELINE" 2>/dev/null )
checkout_rc=$?
git -C "$SNAPSHOT" apply --check "$ITER2_DIFF" 2>$TEST_TEMP_DIR/apply-err.log
apply_rc=$?
set -e

if [[ $clone_rc -eq 0 && $checkout_rc -eq 0 && $apply_rc -eq 0 ]]; then
    assert_pass "cumulative diff.patch applies cleanly to baseline snapshot (test-stage rsync model)"
else
    apply_err="$(head -3 $TEST_TEMP_DIR/apply-err.log 2>/dev/null || echo '<no err>')"
    assert_fail "cumulative diff.patch applies cleanly to baseline snapshot" \
        "clone_rc=$clone_rc checkout_rc=$checkout_rc apply_rc=$apply_rc apply_err=$apply_err"
fi

cd "$REPO_ROOT"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
