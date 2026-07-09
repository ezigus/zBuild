#!/usr/bin/env bash
# Tests: review-lens + review-report judge the FULL-BRANCH merge-base change
# bundle, like `review` (#896), instead of the per-run incremental diff.patch
# (Issue B, #952). The observed #952 failure: build converged with an EMPTY
# diff.patch (work already committed), so the lens change bundle was empty, the
# `[[ -s "$evidence" ]]` guard skipped redaction, and route_to_model refused
# every lens on the C6 precondition.
#
# MB1: empty diff.patch + committed branch work → zbuild_change_bundle resolves
#      the NON-empty merge-base diff (writes branch-diff.patch). This is the fix.
# MB2: the resolved bundle content == `git diff <merge-base> HEAD` — the SAME
#      basis `review` uses (dedupe: one zbuild_resolve_merge_base resolver).
# MB3: with the empty diff.patch, the lens actually RUNS (reaches route_to_model
#      with non-empty evidence) instead of degrading on empty evidence.
# MB4: no resolvable base → falls back to the diff.patch artifact (no crash).
# MB5: source-level dedupe — lens/report share zbuild_change_bundle /
#      zbuild_resolve_merge_base via the shared merge-base.sh lib. (The retired
#      review agent plugin, #979, is no longer part of this dedupe assertion.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-lens/report judge the merge-base change bundle (Issue B, #952)"
setup_test_env "review-lens-report-merge-base-bundle"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
# shellcheck source=../../plugins/agent/review-report/plugin.sh
source "$REPO_ROOT/plugins/agent/review-report/plugin.sh"

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

# ─── MB1: empty diff.patch → change bundle resolves the NON-empty branch diff ─
print_test_section "MB1: empty diff.patch → merge-base bundle is non-empty (the #952 fix)"
BUNDLE="$(cd "$REPO" && zbuild_change_bundle "$ART")"
assert_eq "MB1 bundle path is branch-diff.patch" "$ART/branch-diff.patch" "$BUNDLE"
if [[ -s "$BUNDLE" ]]; then
    assert_pass "MB1 branch-diff bundle is non-empty despite empty diff.patch"
else
    assert_fail "MB1 branch-diff bundle should be non-empty" "empty"
fi
if grep -qF 'BRANCH_HUNK_LINE' "$BUNDLE"; then
    assert_pass "MB1 bundle contains the committed branch hunk"
else
    assert_fail "MB1 bundle missing the branch hunk" "n/a"
fi
# Prove the pre-fix path really was starved: the incremental diff.patch is empty.
if [[ -s "$ART/diff.patch" ]]; then
    assert_fail "MB1 diff.patch should be empty (the bug condition)" "non-empty"
else
    assert_pass "MB1 incremental diff.patch is empty (pre-fix evidence was empty)"
fi

# ─── MB2: SAME basis as review — bundle == git diff <merge-base> HEAD ─────────
print_test_section "MB2: bundle content == git diff <merge-base> HEAD (one shared basis)"
REVIEW_BASIS="$(cd "$REPO" && git diff "$(zbuild_resolve_merge_base)" HEAD 2>/dev/null || true)"
assert_eq "MB2 lens/report bundle == the review merge-base diff" \
    "$REVIEW_BASIS" "$(cat "$BUNDLE")"

# ─── MB3: evidence resolves to the non-empty bundle AND the lens RUNS ─────────
print_test_section "MB3: lens evidence is non-empty → lens reaches route_to_model"
# `security` has no per-lens artifact → falls through to the shared bundle.
EV="$(_review_lens_evidence_path "security" "$ART" "$BUNDLE")"
assert_eq "MB3 lens evidence path is the merge-base bundle" "$BUNDLE" "$EV"
if [[ -s "$EV" ]]; then
    assert_pass "MB3 lens evidence is non-empty (redaction/route no longer skipped)"
else
    assert_fail "MB3 lens evidence should be non-empty" "empty"
fi

# Stub the chokepoint (cp passthrough) + the model call to prove the lens does
# NOT take the empty-evidence degrade path. route_to_model runs in a command
# substitution (subshell) → record calls to a FILE, not a variable.
RL_CALLS="$TEST_TEMP_DIR/route-calls.log"; : > "$RL_CALLS"
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin
apply_scope_redaction() { cp "$1" "$2"; return 0; }
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$RL_CALLS"; printf '%s' '{"score":7,"findings":[]}'; return 0; }
OUT="$ART/lens-security.json"
set +e
_review_lens_run_inner "security" "$SCOPE" "$EV" "$OUT" "$ART"
_rc=$?
set -e
assert_eq "MB3 _review_lens_run_inner returns 0" "0" "$_rc"
if [[ "$(wc -l < "$RL_CALLS" | tr -d ' ')" -ge 1 ]]; then
    assert_pass "MB3 lens reached route_to_model (ran, not degraded on empty evidence)"
else
    assert_fail "MB3 lens should have called route_to_model" "0 calls"
fi
assert_eq "MB3 lens result carries the model score (proves it ran)" \
    "7" "$(jq -r '.score' "$OUT" 2>/dev/null || echo MISSING)"

# ─── MB4: no resolvable base → fall back to diff.patch (no crash) ─────────────
print_test_section "MB4: no merge-base → falls back to diff.patch artifact"
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
printf 'FALLBACK_DIFF_PATCH\n' > "$ART2/diff.patch"
BUNDLE2="$(cd "$REPO2" && zbuild_change_bundle "$ART2")"
assert_eq "MB4 no base → bundle path is diff.patch" "$ART2/diff.patch" "$BUNDLE2"
if [[ ! -e "$ART2/branch-diff.patch" ]]; then
    assert_pass "MB4 no branch-diff.patch written when no base resolves"
else
    assert_fail "MB4 branch-diff.patch should not exist without a base" "present"
fi

# ─── MB5: source-level dedupe — one shared resolver across lens + report ──────
print_test_section "MB5: lens/report share the resolver via merge-base.sh"
for _p in review-lens review-report; do
    _src="$REPO_ROOT/plugins/agent/$_p/plugin.sh"
    if grep -q 'scripts/lib/merge-base.sh' "$_src"; then
        assert_pass "MB5 $_p sources shared merge-base.sh"
    else
        assert_fail "MB5 $_p must source shared merge-base.sh" "absent"
    fi
done
for _p in review-lens review-report; do
    if grep -q 'zbuild_change_bundle' "$REPO_ROOT/plugins/agent/$_p/plugin.sh"; then
        assert_pass "MB5 $_p resolves the change bundle via zbuild_change_bundle"
    else
        assert_fail "MB5 $_p must use zbuild_change_bundle" "absent"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
