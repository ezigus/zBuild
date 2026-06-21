#!/usr/bin/env bash
# Unit test (#661 / Wave 12-B / ADR-020 amendment):
# After build commits per-iter work (#608), diff.patch MUST be the cumulative
# baseline→HEAD delta (`git diff $intake_baseline..HEAD`), NOT the per-iter
# uncommitted working-tree delta (`git diff HEAD`). With multiple commits
# between baseline and HEAD, diff.patch must contain ALL of them, not just
# the most recent iter's changes.
#
# Failure mode this guards: the legacy `git diff HEAD > diff.patch` (captured
# BEFORE _build_commit_iteration in pre-#661 code) returned the
# pre-commit working tree diff; after the commit landed, that diff equaled
# the head-relative diff and downstream test's `git apply --check` would
# re-apply already-landed content, exploding with "patch does not apply".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #661: cumulative diff.patch since intake baseline"
setup_test_env "build-diff-cumulative"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-cumulative-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

# Operator override so per-iter redaction stub satisfies route_loop.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Source event-bus + build plugin.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── Build a throwaway repo with baseline + pre-existing commit on branch ────
# Layout:
#   commit M0 = initial seed
#   <— intake baseline captured here, intake-baseline-ref.txt = $BASELINE
#   commit M1 = pre-existing branch commit (e.g., from a prior build iter)
#   <— this iter: agent writes file_iter2.txt → commit M2
# Expectation: diff.patch == git diff $BASELINE..HEAD (contains BOTH M1 + M2)
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    echo "seed" > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m "M0 seed"
) >/dev/null

BASELINE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s' "$BASELINE" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"

# Pre-existing prior-iter commit on the branch (file_iter1.txt).
(
    cd "$REPO"
    echo "iter1 content" > file_iter1.txt
    git add file_iter1.txt
    git -c commit.gpgsign=false commit -q -m "M1 prior iter work"
) >/dev/null

# ─── Stub route_to_model_loop: simulates the LLM editing file_iter2.txt ─────
# The loop returns rc=0 with terminated_reason=done_sentinel. The build plugin
# will then capture diff, scope-check, commit (via _build_commit_iteration),
# then rewrite diff.patch to the cumulative baseline→HEAD delta (#661).
# shellcheck disable=SC2317
route_to_model_loop() {
    # Args: tier prompt_file repo_root max_iter [--scope-allowlist CSV ...]
    local _repo="$3"
    # Mimic LLM Write tool: drop file_iter2.txt into the repo.
    echo "iter2 content from LLM" > "$_repo/file_iter2.txt"
    # Populate the loop globals the plugin reads after return.
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=5
    _ROUTE_LOOP_OUTPUT_TOKENS=3
    _ROUTE_LOOP_LAST_RESPONSE=$'edited file_iter2.txt\nCOMMIT_SUMMARY: iter2 work\nLOOP_COMPLETE'
    return 0
}
export -f route_to_model_loop 2>/dev/null || true

# Suppress the optional deferred-banner-close helper and route resolver.
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 1; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    # Identity passthrough — copy input to output if both given as files.
    if [[ -n "${1:-}" && -n "${2:-}" && -f "$1" ]]; then
        cp -f "$1" "$2"
    fi
    return 0
}

# ─── Prepare plan.json + scope manifest ─────────────────────────────────────
ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
DIFF_PATCH="$ARTIFACT_DIR/diff.patch"
SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"

cat > "$PLAN_JSON" <<JSON
{
  "title": "Wave 12-B cumulative diff test",
  "files": ["file_iter2.txt"]
}
JSON
echo "scope: file_iter2.txt" > "$SCOPE_MANIFEST"

# Build plugin uses `pwd` semantics via repo_root inference; explicit cwd in
# the inner helper is the redacted prompt's repo. The plugin uses
# `git -C "$repo_root"` so we need to set repo_root via the working dir.
cd "$REPO"

# ─── Drive the inner runner ──────────────────────────────────────────────────
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON" \
    "$DIFF_PATCH" \
    "$SUMMARY_JSON" \
    "$ARTIFACT_DIR" \
    >/dev/null 2>&1 || true

# ─── Assertion 1: diff.patch exists and is non-empty ────────────────────────
if [[ -s "$DIFF_PATCH" ]]; then
    assert_pass "A1: diff.patch is non-empty after build"
else
    assert_fail "A1: diff.patch is non-empty after build" \
        "size=$(wc -c < "$DIFF_PATCH" 2>/dev/null || echo 0)"
fi

# ─── Assertion 2: diff.patch byte-equals `git diff $BASELINE..HEAD` ─────────
EXPECTED="$TEST_TEMP_DIR/expected.patch"
git -C "$REPO" diff "$BASELINE..HEAD" > "$EXPECTED" 2>/dev/null || true

if cmp -s "$DIFF_PATCH" "$EXPECTED"; then
    assert_pass "A2: diff.patch byte-equals git diff \$baseline..HEAD"
else
    actual_sha="$(shasum -a 256 "$DIFF_PATCH" 2>/dev/null | cut -d' ' -f1)"
    expected_sha="$(shasum -a 256 "$EXPECTED" 2>/dev/null | cut -d' ' -f1)"
    actual_size="$(wc -c < "$DIFF_PATCH" 2>/dev/null || echo 0)"
    expected_size="$(wc -c < "$EXPECTED" 2>/dev/null || echo 0)"
    assert_fail "A2: diff.patch byte-equals git diff \$baseline..HEAD" \
        "actual_size=$actual_size expected_size=$expected_size actual_sha=$actual_sha expected_sha=$expected_sha"
fi

# ─── Assertion 3: diff.patch contains BOTH file_iter1.txt + file_iter2.txt ──
if grep -q 'file_iter1.txt' "$DIFF_PATCH" && grep -q 'file_iter2.txt' "$DIFF_PATCH"; then
    assert_pass "A3: diff.patch contains BOTH prior-iter (M1) and current-iter (M2) work — cumulative"
else
    has1="$(grep -c 'file_iter1.txt' "$DIFF_PATCH" 2>/dev/null || echo 0)"
    has2="$(grep -c 'file_iter2.txt' "$DIFF_PATCH" 2>/dev/null || echo 0)"
    assert_fail "A3: diff.patch contains BOTH prior-iter + current-iter work" \
        "file_iter1_lines=$has1 file_iter2_lines=$has2"
fi

# ─── Assertion 4: diff.patch ends with \n (#530 invariant on the new path) ──
last_byte="$(tail -c1 "$DIFF_PATCH" | od -An -tx1 | tr -d ' \n')"
if [[ "$last_byte" == "0a" ]]; then
    assert_pass "A4: diff.patch ends with newline (#530 invariant preserved)"
else
    assert_fail "A4: diff.patch ends with newline" "last_byte=0x$last_byte"
fi

# ─── Assertion 5: per-iter commit fired (file_iter2.txt is at HEAD) ─────────
if grep -q 'file_iter2.txt' <<< "$(git -C "$REPO" ls-tree --name-only HEAD)"; then
    assert_pass "A5: commit landed file_iter2.txt at HEAD (#608 preserved)"
else
    assert_fail "A5: commit landed file_iter2.txt at HEAD" "ls-tree=$(git -C "$REPO" ls-tree --name-only HEAD | tr '\n' ' ')"
fi

# ─── Assertion 6: fallback path (no baseline ref) preserves `git diff HEAD` ─
print_test_section "F: fallback when intake-baseline-ref.txt absent"
rm -f "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"

# Fresh repo for fallback case.
REPO2="$TEST_TEMP_DIR/repo2"
mkdir -p "$REPO2"
(
    cd "$REPO2"
    git init -q
    git config user.email t@t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m "seed"
) >/dev/null

ART2="$ZBUILD_STATE_DIR/artifacts2"
mkdir -p "$ART2"
cat > "$ART2/plan.json" <<JSON
{ "title": "fallback test", "files": ["fallback.txt"] }
JSON
echo "scope: fallback.txt" > "$ZBUILD_STATE_DIR/scope-manifest2.md"

# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    echo "fallback content" > "$_repo/fallback.txt"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=5
    _ROUTE_LOOP_OUTPUT_TOKENS=3
    _ROUTE_LOOP_LAST_RESPONSE=$'wrote fallback.txt\nLOOP_COMPLETE'
    return 0
}

cd "$REPO2"
_build_stage_run_inner \
    "$ZBUILD_STATE_DIR/scope-manifest2.md" \
    "$ART2/plan.json" \
    "$ART2/diff.patch" \
    "$ART2/build-summary.json" \
    "$ART2" \
    >/dev/null 2>&1 || true

# With no baseline + after the per-iter commit, `git diff HEAD` is empty.
# Fallback writes empty diff — this preserves pre-#617 resumed-run behavior.
fallback_size="$(wc -c < "$ART2/diff.patch" 2>/dev/null | tr -d ' ' || echo 0)"
if [[ "$fallback_size" == "0" ]]; then
    assert_pass "F1: fallback path with no baseline yields empty diff (post-commit git diff HEAD)"
else
    assert_fail "F1: fallback path yields empty diff" "size=$fallback_size"
fi

# Confirm the commit still landed in fallback mode.
if grep -q 'fallback.txt' <<< "$(git -C "$REPO2" ls-tree --name-only HEAD)"; then
    assert_pass "F2: fallback commit landed fallback.txt at HEAD"
else
    assert_fail "F2: fallback commit landed at HEAD" "ls-tree empty"
fi

cd "$REPO_ROOT"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
