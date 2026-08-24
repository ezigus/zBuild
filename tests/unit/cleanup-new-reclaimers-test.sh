#!/usr/bin/env bash
# tests/unit/cleanup-new-reclaimers-test.sh
# The four categories that had no reclaimer at all, and the issue-close clock.
#
# SPEC-1[change]: per-stage scratch is reclaimable; an active run's scratch is kept.
# SPEC-2[change]: zbuild/state/issue-* branches are reclaimable — nothing pruned them before.
# SPEC-3[change]: orch pool dirs under ${TMPDIR}/zbuild-runs/<id>/ are reclaimable.
# SPEC-4[change]: the ADR-011 content cache is reclaimable; the memory store is NOT a target.
# SPEC-5[change]: issue-keyed refs age from the issue's CLOSE, not from last touch.
# SPEC-6[guard]:  an issue whose state cannot be established is KEPT, never pruned.
# SPEC-7[guard]:  the shared dir applier refuses a target outside its declared root.
# SPEC-8[guard]:  --force does NOT prune the work branch of a provably OPEN issue.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"

print_test_header "cleanup — the four missing reclaimers + the issue-close clock"
setup_test_env "cleanup-new-reclaimers"

_now() { date +%s; }
# Backdate a directory by N days.
_backdate() {
    local p="$1" days="$2" ts
    ts=$(( $(_now) - days * 86400 ))
    touch -t "$(date -u -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null \
        || date -u -d "@$ts" +%Y%m%d%H%M.%S)" "$p" 2>/dev/null || true
}
_decision_for() {   # <plan> <target-substring>
    printf '%s\n' "$1" | /usr/bin/grep -F "$2" | head -1 | cut -f2
}
_reason_for() {
    printf '%s\n' "$1" | /usr/bin/grep -F "$2" | head -1 | cut -f3-
}

# ── SPEC-1: scratch ─────────────────────────────────────────────────────────
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_ROOT/runs/oldrun/scratch/build" \
         "$ZBUILD_STATE_ROOT/runs/newrun/scratch/test"
: > "$ZBUILD_STATE_ROOT/runs/oldrun/scratch/build/staging.txt"
_backdate "$ZBUILD_STATE_ROOT/runs/oldrun/scratch" 30

_scratch_plan="$(_cleanup_scan_scratch 7)"
assert_eq "[SPEC-1] a 30-day-old run's scratch is a prune candidate" \
    "prune" "$(_decision_for "$_scratch_plan" "oldrun/scratch")"
assert_eq "[SPEC-1] a fresh run's scratch is kept" \
    "skip" "$(_decision_for "$_scratch_plan" "newrun/scratch")"
# #1634: the skip must NAME its guard, so a clean scan and a broken scan differ.
if [[ -n "$(_reason_for "$_scratch_plan" "newrun/scratch")" ]]; then
    assert_pass "[SPEC-1] the kept entry names the guard that fired"
else
    assert_fail "[SPEC-1] a skip must name its guard" "empty reason"
fi

# Active run is kept regardless of age. Save and restore the real predicate by
# definition — cleanup.sh has a load guard (`_ZBUILD_CLEANUP_LOADED`), so an
# `unset -f` + re-source leaves it permanently undefined and every later scanner
# silently loses its active-run check.
_ORIG_IS_ACTIVE="$(declare -f _cleanup_is_active_run)"
_cleanup_is_active_run() { [[ "$1" == "oldrun" ]]; }
_scratch_active="$(_cleanup_scan_scratch 7)"
assert_eq "[SPEC-1] an ACTIVE run's scratch is kept even at 30 days" \
    "skip" "$(_decision_for "$_scratch_active" "oldrun/scratch")"
assert_contains "[SPEC-1] the active-run skip says so" \
    "$(_reason_for "$_scratch_active" "oldrun/scratch")" "active run"
eval "$_ORIG_IS_ACTIVE"
if declare -F _cleanup_is_active_run >/dev/null 2>&1; then
    assert_pass "[SPEC-1] the real active-run predicate is restored after stubbing"
else
    assert_fail "[SPEC-1] the real active-run predicate must be restored" "still undefined"
fi

# ── SPEC-2: state branches ──────────────────────────────────────────────────
# Nothing pruned these before: _cleanup_scan_branches filters strictly on
# `zbuild/issue-*`, so `zbuild/state/issue-*` was never even a candidate (#1632).
# Exercised against a real throwaway repo — the scanner shells out to git, so a
# pure-function test would prove nothing about whether it can see a branch.
_SB_REPO="$TEST_TEMP_DIR/sbrepo"
mkdir -p "$_SB_REPO"
(
    cd "$_SB_REPO" || exit 1
    git init -q -b main . 2>/dev/null
    git config user.email t@e.st; git config user.name t
    : > f; git add f; git commit -q -m init
    git branch zbuild/state/issue-200      # issue closed 30d ago (stubbed below)
    git branch zbuild/state/issue-100      # issue open      (stubbed below)
    git branch zbuild/issue-200-work       # a WORK branch, must not be scanned here
) >/dev/null 2>&1

# Stub the GitHub lookups before scanning — no network in tests.
_cleanup_issue_state() { case "$1" in 100) printf 'open';; 200) printf 'closed';; \
    300) printf 'missing';; *) printf 'unknown';; esac; }
_cleanup_issue_closed_age_days() { [[ "$1" == "200" ]] && printf '30'; }

_sb_plan="$( cd "$_SB_REPO" && _cleanup_scan_state_branches 7 )"

assert_eq "[SPEC-2] a state branch whose issue closed 30d ago is a prune candidate" \
    "prune" "$(_decision_for "$_sb_plan" "zbuild/state/issue-200")"
assert_eq "[SPEC-2] a state branch for an OPEN issue is kept" \
    "skip" "$(_decision_for "$_sb_plan" "zbuild/state/issue-100")"

# The scanner owns the state namespace ONLY — work branches belong to
# _cleanup_scan_branches, and double-scanning would double-report them.
if printf '%s\n' "$_sb_plan" | /usr/bin/grep -q 'zbuild/issue-200-work'; then
    assert_fail "[SPEC-2] the state scanner must not claim work branches" "$_sb_plan"
else
    assert_pass "[SPEC-2] the state scanner leaves zbuild/issue-* to the branch scanner"
fi

# Positive control: without the issue-close clock nothing here is prunable at
# all, so prove the branch really is reachable and the decision is the variable.
if [[ -n "$_sb_plan" ]]; then
    assert_pass "[SPEC-2] the scanner sees state branches at all (it reported $(printf '%s\n' "$_sb_plan" | /usr/bin/grep -c .) )"
else
    assert_fail "[SPEC-2] the scanner reported nothing — it cannot see state branches" "empty plan"
fi

# ── SPEC-8[guard]: --force must not outrank a provably open issue ───────────
# The regression this exists for: the issue-close block emitted a decision for
# `prune` and for `skip without --force`, but fell THROUGH for `skip WITH
# --force` — so `cleanup --force` re-classified an open issue's work branch as
# `prune  force` and deleted the branch holding its unmerged code. Caught in
# review, not by the first version of this file.
#
# The fixture needs a real UPSTREAM. _cleanup_has_unpushed_commits treats "no
# upstream" as unpushed and skips, which sits AHEAD of the issue clock — a
# first attempt at this test used plain local branches and passed vacuously,
# reporting `skip  unpushed commits / no upstream` while never reaching the code
# under test. Its positive control is what exposed that.
_FR_REMOTE="$TEST_TEMP_DIR/remote.git"
_FR_REPO="$TEST_TEMP_DIR/forcerepo"
git init -q --bare "$_FR_REMOTE" 2>/dev/null
mkdir -p "$_FR_REPO"
(
    cd "$_FR_REPO" || exit 1
    git init -q -b main .
    git config user.email t@e.st; git config user.name t
    git remote add origin "$_FR_REMOTE"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
    git branch zbuild/issue-100-open        # issue OPEN   → must survive --force
    git branch zbuild/issue-300-gone        # issue MISSING, age 0 → --force prunes
    git push -q -u origin zbuild/issue-100-open zbuild/issue-300-gone
    git checkout -q main
) >/dev/null 2>&1

_fr_plan="$( cd "$_FR_REPO" && _cleanup_scan_branches "true" 7 )"

# Prove the fixture actually reaches the code under test before asserting on it.
if printf '%s\n' "$_fr_plan" | /usr/bin/grep -q 'unpushed'; then
    assert_fail "[SPEC-8] fixture must get PAST the unpushed guard to test the issue clock" \
        "$_fr_plan"
else
    assert_pass "[SPEC-8] fixture branches are pushed, so the issue clock is reached"
fi

assert_eq "[SPEC-8] --force does NOT prune the work branch of an OPEN issue" \
    "skip" "$(_decision_for "$_fr_plan" "zbuild/issue-100-open")"
assert_contains "[SPEC-8] and says the open issue outranked --force" \
    "$(_reason_for "$_fr_plan" "zbuild/issue-100-open")" "outrank"

# Positive control, same invocation: --force still prunes a branch nothing
# protects. Without it, a scanner that skipped everything would satisfy the
# assertion above.
assert_eq "[SPEC-8] positive control: --force still prunes where nothing protects the branch" \
    "prune" "$(_decision_for "$_fr_plan" "zbuild/issue-300-gone")"

# ── SPEC-3: orch pools ──────────────────────────────────────────────────────
export TMPDIR="$TEST_TEMP_DIR/tmp"; mkdir -p "$TMPDIR/zbuild-runs/deadpool"
: > "$TMPDIR/zbuild-runs/deadpool/slot0"
_backdate "$TMPDIR/zbuild-runs/deadpool" 2
_pool_plan="$(_cleanup_scan_orch_pools 1)"
assert_eq "[SPEC-3] a dead run's orch pool dir is a prune candidate" \
    "prune" "$(_decision_for "$_pool_plan" "zbuild-runs/deadpool")"

# ── SPEC-4: cache, and memory is NOT a target ───────────────────────────────
export ZBUILD_CACHE_DIR="$TEST_TEMP_DIR/cache"
mkdir -p "$ZBUILD_CACHE_DIR/oldkey" "$ZBUILD_CACHE_DIR/newkey"
_backdate "$ZBUILD_CACHE_DIR/oldkey" 30
_cache_plan="$(_cleanup_scan_cache 7)"
assert_eq "[SPEC-4] a stale cache key is a prune candidate" \
    "prune" "$(_decision_for "$_cache_plan" "cache/oldkey")"
assert_eq "[SPEC-4] a fresh cache key is kept" \
    "skip" "$(_decision_for "$_cache_plan" "cache/newkey")"

# GUARD: no scanner anywhere may target the memory store. Deleting it would
# discard knowledge deliberately kept agnostic to the issues it supports.
_mem_refs="$(/usr/bin/grep -nE 'memory\.db|_scan_memory|memory_namespace_clear' \
    "$REPO_ROOT/scripts/lib/cleanup.sh" || true)"
if [[ -z "$_mem_refs" ]]; then
    assert_pass "[SPEC-4] cleanup.sh never targets the memory store"
else
    assert_fail "[SPEC-4] the memory store must never be a cleanup target" "$_mem_refs"
fi

# ── SPEC-5 / SPEC-6: the issue-close clock ──────────────────────────────────
assert_eq "[SPEC-5] an issue number is parsed from a work branch" \
    "1809" "$(_cleanup_issue_from_ref 'zbuild/issue-1809-some-slug')"
assert_eq "[SPEC-5] an issue number is parsed from a state branch" \
    "1809" "$(_cleanup_issue_from_ref 'zbuild/state/issue-1809')"

# (GitHub lookups already stubbed above, at SPEC-2.)

_d_open="$(_cleanup_issue_ref_decision 'zbuild/state/issue-100' 7 999)"
assert_eq "[SPEC-5] a branch for an OPEN issue is kept, however old" \
    "skip" "${_d_open%%$'\t'*}"
assert_contains "[SPEC-5] and says why" "$_d_open" "is open"

_d_closed="$(_cleanup_issue_ref_decision 'zbuild/state/issue-200' 7 0)"
assert_eq "[SPEC-5] a branch whose issue closed 30d ago is pruned even at age 0" \
    "prune" "${_d_closed%%$'\t'*}"

_d_unknown="$(_cleanup_issue_ref_decision 'zbuild/state/issue-999' 7 999)"
assert_eq "[SPEC-6] an issue whose state cannot be established is KEPT" \
    "skip" "${_d_unknown%%$'\t'*}"
assert_contains "[SPEC-6] and names the fail-closed reason" "$_d_unknown" "fail-closed"

_d_missing="$(_cleanup_issue_ref_decision 'zbuild/state/issue-300' 7 99)"
assert_eq "[SPEC-5] a vanished issue falls back to plain age (#1632)" \
    "prune" "${_d_missing%%$'\t'*}"

# ── SPEC-7: the dir applier refuses to leave its root ───────────────────────
_outside="$TEST_TEMP_DIR/OUTSIDE"; mkdir -p "$_outside"; : > "$_outside/canary"
_cleanup_apply_dir_plan "$_outside"$'\tprune\tcrafted' "false" "$ZBUILD_CACHE_DIR"
assert_file_exists "[SPEC-7] a target outside the declared root is refused" "$_outside/canary"

# POSITIVE CONTROL. Without this the assertion above passes even if the applier
# does nothing at all — "refused" and "broken" are indistinguishable otherwise.
mkdir -p "$ZBUILD_CACHE_DIR/doomed"; : > "$ZBUILD_CACHE_DIR/doomed/x"
_cleanup_apply_dir_plan "$ZBUILD_CACHE_DIR/doomed"$'\tprune\tage=99d' "false" "$ZBUILD_CACHE_DIR"
assert_file_not_exists "[SPEC-7] positive control: a target INSIDE the root is removed" \
    "$ZBUILD_CACHE_DIR/doomed/x"

# And dry-run removes nothing.
mkdir -p "$ZBUILD_CACHE_DIR/spared"; : > "$ZBUILD_CACHE_DIR/spared/x"
_cleanup_apply_dir_plan "$ZBUILD_CACHE_DIR/spared"$'\tprune\tage=99d' "true" "$ZBUILD_CACHE_DIR"
assert_file_exists "[SPEC-7] dry-run removes nothing" "$ZBUILD_CACHE_DIR/spared/x"
# And the root itself is never removed, only things strictly inside it.
_cleanup_apply_dir_plan "$ZBUILD_CACHE_DIR"$'\tprune\tcrafted' "false" "$ZBUILD_CACHE_DIR"
if [[ -d "$ZBUILD_CACHE_DIR" ]]; then
    assert_pass "[SPEC-7] the root itself is never removed"
else
    assert_fail "[SPEC-7] the root itself must never be removed" "$ZBUILD_CACHE_DIR gone"
fi

# ── SPEC-9[change]: the REMOTE scope, which is the one CI needs (#1632) ─────
# A CI runner is a fresh checkout: it has no local state branches at all, so a
# local-only scan reports nothing and reads as "nothing to reclaim" rather than
# "wrong scope". The remote scope asks origin.
#
# The fixture is deliberately built so `git branch -r` CANNOT see the branch —
# it is pushed to the bare remote from a DIFFERENT clone, so this clone has no
# remote-tracking ref for it. That is the shape actions/checkout produces with
# its shallow single-branch default, and it is why the scanner uses ls-remote:
# a remote-tracking scan would silently report nothing here.
print_test_section "[SPEC-9][change] remote scope sees branches this clone never fetched"

_RS_REMOTE="$TEST_TEMP_DIR/rs-remote.git"
_RS_PUSHER="$TEST_TEMP_DIR/rs-pusher"
_RS_SCANNER="$TEST_TEMP_DIR/rs-scanner"
git init -q --bare "$_RS_REMOTE" 2>/dev/null
mkdir -p "$_RS_PUSHER"
(
    cd "$_RS_PUSHER" || exit 1
    git init -q -b main .
    git config user.email t@e.st; git config user.name t
    git remote add origin "$_RS_REMOTE"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
    git branch zbuild/state/issue-200        # closed 30d ago per the stubs above
    git branch zbuild/state/issue-100        # open
    # A WORK branch, deliberately deletable: it is outside the state namespace
    # AND outside git's own protection, so the fence is the only thing that can
    # save it. `main` is NOT a usable subject here — a bare remote refuses to
    # delete its own HEAD branch, so `main` survives whether the fence exists or
    # not, and an ablation of the fence leaves the assertion green.
    git branch zbuild/issue-999-work
    git push -q origin zbuild/state/issue-200 zbuild/state/issue-100 zbuild/issue-999-work
) >/dev/null 2>&1

# A SECOND clone that fetched only main — no remote-tracking refs for either
# state branch. This is the CI shape.
git clone -q --single-branch --branch main "$_RS_REMOTE" "$_RS_SCANNER" 2>/dev/null

# Prove the premise before relying on it: if this clone COULD see them via
# remote-tracking refs, the test would not be testing what it claims to.
_rs_tracking="$( cd "$_RS_SCANNER" && git branch -r --list 'origin/zbuild/state/issue-*' 2>/dev/null | /usr/bin/grep -c . || true )"
assert_eq "[SPEC-9] premise: this clone has NO remote-tracking state refs" "0" "$_rs_tracking"

_rs_plan="$( cd "$_RS_SCANNER" && _cleanup_scan_state_branches 7 remote )"
assert_eq "[SPEC-9] remote scope still finds the closed-issue branch" \
    "prune" "$(_decision_for "$_rs_plan" "zbuild/state/issue-200")"
assert_eq "[SPEC-9] remote scope keeps the open-issue branch" \
    "skip" "$(_decision_for "$_rs_plan" "zbuild/state/issue-100")"

# The two scopes are genuinely different questions: the LOCAL scan of the same
# clone must find nothing, or the remote result above proves nothing.
_rs_local="$( cd "$_RS_SCANNER" && _cleanup_scan_state_branches 7 )"
if [[ -z "$_rs_local" ]]; then
    assert_pass "[SPEC-9] the local scope correctly finds nothing in a fresh clone"
else
    assert_fail "[SPEC-9] the local scope should find nothing here" "$_rs_local"
fi

# ── SPEC-10[guard]: the remote applier is fenced and honours dry-run ─────────
# Deleting a branch on ORIGIN is the most destructive thing in this file, and it
# is driven by a plan line — which is data. The namespace fence makes a
# malformed or crafted line inert rather than destructive.
print_test_section "[SPEC-10][guard] the remote applier deletes only inside its namespace"

_rs_remote_has() {
    ( cd "$_RS_SCANNER" && git ls-remote --heads origin "refs/heads/$1" 2>/dev/null | /usr/bin/grep -c . ) || true
}

# Dry-run deletes nothing, even for a prune line.
( cd "$_RS_SCANNER" && _cleanup_apply_remote_branch_plan \
    "zbuild/state/issue-200"$'\tprune\tissue closed 30d ago' "true" )
assert_eq "[SPEC-10] dry-run deletes nothing from origin" "1" "$(_rs_remote_has zbuild/state/issue-200)"

# A crafted line outside the namespace is refused. The subject is a WORK branch,
# not `main`: a bare remote refuses to delete its own HEAD, so `main` would
# survive with or without the fence and the assertion would be inert. Ablating
# the fence must redden this — and with `main` as the subject, it did not.
( cd "$_RS_SCANNER" && _cleanup_apply_remote_branch_plan \
    "zbuild/issue-999-work"$'\tprune\tcrafted' "false" )
assert_eq "[SPEC-10] a prune line outside the state namespace is refused" \
    "1" "$(_rs_remote_has zbuild/issue-999-work)"

# And `main` too, belt-and-braces — this one IS partly git's own protection, and
# is kept as a second line of evidence rather than as the primary assertion.
( cd "$_RS_SCANNER" && _cleanup_apply_remote_branch_plan \
    "main"$'\tprune\tcrafted' "false" )
assert_eq "[SPEC-10] a prune line naming main is refused" "1" "$(_rs_remote_has main)"

# Positive control: inside the namespace, apply really does delete — otherwise
# the two assertions above would pass on a function that does nothing at all.
( cd "$_RS_SCANNER" && _cleanup_apply_remote_branch_plan \
    "zbuild/state/issue-200"$'\tprune\tissue closed 30d ago' "false" )
assert_eq "[SPEC-10] positive control: an in-namespace prune IS deleted" \
    "0" "$(_rs_remote_has zbuild/state/issue-200)"

# And a `skip` line is never acted on.
( cd "$_RS_SCANNER" && _cleanup_apply_remote_branch_plan \
    "zbuild/state/issue-100"$'\tskip\tissue is open' "false" )
assert_eq "[SPEC-10] a skip line is never deleted" "1" "$(_rs_remote_has zbuild/state/issue-100)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
