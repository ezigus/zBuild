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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
