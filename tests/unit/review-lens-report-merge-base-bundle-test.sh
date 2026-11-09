#!/usr/bin/env bash
# Tests: review-lens judges the FULL-BRANCH merge-base change
# bundle, like `review` (#896), instead of the per-run incremental diff.patch
# (Issue B, #952). The observed #952 failure: build converged with an EMPTY
# diff.patch (work already committed), so the lens change bundle was empty, the
# `[[ -s "$evidence" ]]` guard skipped redaction, and route_to_model refused
# every lens on the C6 precondition.
#
# #2507 (ADR-072 §7): the lens is pointed at the change — the commit the branch
# started from and the files it changed — not given the diff; these hold the
# same basis for it.
#
# MB1: empty diff.patch + committed branch work → the change named to the lens
#      is the whole branch's: the file the branch changed. This is the fix.
# MB2: its starting commit is the merge-base — the SAME basis `review` uses
#      (one zbuild_resolve_merge_base resolver).
# MB3: with the empty diff.patch, the lens actually RUNS (reaches route_to_model
#      with the change named) instead of degrading on an empty change.
# MB4: no resolvable base → the lens is pointed at the diff.patch (no crash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-lens judges the merge-base change bundle (Issue B, #952)"
setup_test_env "review-lens-report-merge-base-bundle"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

# ─── Repo: main baseline + feature branch whose work is ALREADY committed ─────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q -b main
    git config user.email "test@zbuild.local"; git config user.name "Test"
    mkdir -p core
    printf 'a\n' > core/foo.sh
    git add core/foo.sh; git commit -q -m "base"
    git checkout -q -b feat/work
    printf 'a\nBRANCH_HUNK_LINE\nc\n' > core/foo.sh
    git add core/foo.sh; git commit -q -m "work (pre-committed)"
)
ART="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$ART"
SCOPE="$TEST_TEMP_DIR/state/scope-manifest.md"
printf '+ core/\n' > "$SCOPE"
# The exact bug condition: the per-run incremental diff is EMPTY.
: > "$ART/diff.patch"

# ─── MB1 / MB2: the change named is the whole branch's ─────────────────────
print_test_section "MB1/MB2: empty diff.patch → the lens is named the branch's change (the #952 fix)"
_cf=""; _cfp=""
( cd "$REPO" && zbuild_change_files_v _cf _cfp "$ART/diff.patch" && printf '%s\n%s' "$_ZB_CHANGE_BASE" "$_cf" ) > "$TEST_TEMP_DIR/cf.txt"
_cf="$(cat "$TEST_TEMP_DIR/cf.txt")"
assert_contains "MB1 the change names the file the committed branch work changed" "$_cf" "core/foo.sh"
if [[ -s "$ART/diff.patch" ]]; then
    assert_fail "MB1 diff.patch should be empty (the bug condition)" "non-empty"
else
    assert_pass "MB1 incremental diff.patch is empty (pre-fix evidence was empty)"
fi
REVIEW_BASE="$(cd "$REPO" && zbuild_resolve_merge_base)"
assert_eq "MB2 its starting commit is the review merge-base" "$REVIEW_BASE" "$(head -1 "$TEST_TEMP_DIR/cf.txt")"

# ─── MB3: the lens RUNS ──────────────────────────────────────────────────────
print_test_section "MB3: the lens reaches route_to_model with the change named"
RL_CALLS="$TEST_TEMP_DIR/route-calls.log"; : > "$RL_CALLS"
RL_PROMPT="$TEST_TEMP_DIR/route-prompt.txt"
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin
apply_scope_redaction() { cp "$1" "$2"; return 0; }
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$RL_CALLS"; printf '%s' "$2" > "$RL_PROMPT"; printf '%s' '{"score":7,"findings":[]}'; return 0; }
OUT="$ART/lens-security.json"
set +e
( cd "$REPO" && ZBUILD_REPO_ROOT="$REPO" _review_lens_run_inner "security" "$SCOPE" "$ART/diff.patch" "$OUT" "$ART" )
_rc=$?
set -e
assert_eq "MB3 _review_lens_run_inner returns 0" "0" "$_rc"
if [[ "$(wc -l < "$RL_CALLS" | tr -d ' ')" -ge 1 ]]; then
    assert_pass "MB3 lens reached route_to_model (ran, not degraded on an empty change)"
else
    assert_fail "MB3 lens should have called route_to_model" "0 calls"
fi
assert_contains "MB3 ...with the branch's change named" "$(cat "$RL_PROMPT" 2>/dev/null)" "core/foo.sh"
assert_eq "MB3 lens result carries the model score (proves it ran)" \
    "7" "$(jq -r '.score' "$OUT" 2>/dev/null || echo MISSING)"

# ─── MB4: no resolvable base → pointed at diff.patch (no crash) ──────────────
print_test_section "MB4: no merge-base → pointed at the diff.patch artifact"
REPO2="$TEST_TEMP_DIR/repo2"; mkdir -p "$REPO2"
(
    cd "$REPO2"
    git init -q -b work   # no main / origin/main, single commit → no HEAD~1
    git config user.email "test@zbuild.local"; git config user.name "Test"
    mkdir -p core
    printf 'x\n' > core/bar.sh
    git add core/bar.sh; git commit -q -m "only"
)
ART2="$TEST_TEMP_DIR/state2/artifacts"; mkdir -p "$ART2"
printf 'diff --git a/core/bar.sh b/core/bar.sh\n+FALLBACK_DIFF_PATCH\n' > "$ART2/diff.patch"
_cf2="$(cd "$REPO2" && zbuild_change_files_v _c _f "$ART2/diff.patch" && printf '%s' "$_c")"
assert_contains "MB4 no base → the judge is pointed at diff.patch" "$_cf2" "$ART2/diff.patch"
assert_contains "MB4 ...and the files in it" "$_cf2" "core/bar.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
