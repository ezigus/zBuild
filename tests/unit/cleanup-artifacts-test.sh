#!/usr/bin/env bash
# Tests: scripts/cleanup-artifacts.sh — plan-context cache GC (#1052, Pillar F)
# [SPEC-6] dry-run lists/keeps; --status complete --force removes complete keeps scope_too_large;
#          --max-entries LRU; refuses out-of-root paths; never deletes active run; --older-than by mtime/created_at.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh" 2>/dev/null || true
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup-artifacts.sh (#1052 Pillar F, SPEC-6)"
setup_test_env "cleanup-artifacts"

CLEANUP="$REPO_ROOT/scripts/cleanup-artifacts.sh"

# ── Fake cache builder ───────────────────────────────────────────────────────
# Layout mirrors Pillar E: $ZBUILD_PLAN_CONTEXT_DIR/<repo_id>/<scope_key>/<goal_hash>.{json,md}
export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/plan-context"
# Hermetic state root — never prune the developer's real ~/.zbuild/state/runs.
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"

# Set a file's mtime to N days ago (GNU then BSD touch).
_set_age_days() {
    local path="$1" days="$2" secs
    secs=$(( days * 86400 ))
    if ! touch -d "@$(( $(date +%s) - secs ))" "$path" 2>/dev/null; then
        local ts; ts="$(date -r $(( $(date +%s) - secs )) "+%Y%m%d%H%M.%S")"
        touch -t "$ts" "$path"
    fi
}

# Write a context leaf with status + age (days). created_at set N days ago too.
_write_ctx() {
    local repo="$1" scope="$2" hash="$3" status="$4" age_days="$5"
    local dir="$ZBUILD_PLAN_CONTEXT_DIR/$repo/$scope"
    mkdir -p "$dir"
    local json="$dir/$hash.json" md="$dir/$hash.md"
    local created; created="$(date -u -d "@$(( $(date +%s) - age_days * 86400 ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -r "$(( $(date +%s) - age_days * 86400 ))" "+%Y-%m-%dT%H:%M:%SZ")"
    jq -n --arg h "$hash" --arg s "$status" --arg c "$created" --arg r "$repo" --arg k "$scope" \
        '{schema_version:1, goal_hash:$h, status:$s, repo_id:$r, scope_key:$k, created_at:$c, run_id:"run-x"}' \
        > "$json"
    printf '# plan-context %s\nstatus: %s\n' "$hash" "$status" > "$md"
    _set_age_days "$json" "$age_days"
    _set_age_days "$md" "$age_days"
}

reset_cache() {
    rm -rf "$ZBUILD_PLAN_CONTEXT_DIR"
    # repoA / issue-100: one old complete, one old scope_too_large, one recent complete
    _write_ctx "repoA" "issue-100" "h_old_complete"   "complete"        30
    _write_ctx "repoA" "issue-100" "h_old_stl"        "scope_too_large" 30
    _write_ctx "repoA" "issue-100" "h_recent_complete" "complete"        1
}

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-6] --dry-run lists candidates but deletes nothing
# ─────────────────────────────────────────────────────────────────────────────
reset_cache
out="$(bash "$CLEANUP" --older-than 0d --status complete --dry-run 2>&1)"
if grep -q "WOULD REMOVE" <<<"$out" && grep -q "h_old_complete" <<<"$out"; then
    assert_pass "[SPEC-6] dry-run lists stale complete candidate"
else
    assert_fail "[SPEC-6] dry-run lists stale complete candidate" "got: $out"
fi
if [[ -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-100/h_old_complete.json" ]]; then
    assert_pass "[SPEC-6] dry-run deletes nothing"
else
    assert_fail "[SPEC-6] dry-run deletes nothing"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-6] --status complete --force removes complete, KEEPS scope_too_large
# ─────────────────────────────────────────────────────────────────────────────
reset_cache
bash "$CLEANUP" --older-than 0d --status complete --force >/dev/null 2>&1
if [[ ! -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-100/h_old_complete.json" ]]; then
    assert_pass "[SPEC-6] --force removes stale complete entry"
else
    assert_fail "[SPEC-6] --force removes stale complete entry"
fi
if [[ ! -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-100/h_old_complete.md" ]]; then
    assert_pass "[SPEC-6] --force removes the .md sibling too"
else
    assert_fail "[SPEC-6] --force removes the .md sibling too"
fi
if [[ -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-100/h_old_stl.json" ]]; then
    assert_pass "[SPEC-6] scope_too_large KEPT under --status complete"
else
    assert_fail "[SPEC-6] scope_too_large KEPT under --status complete"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-6] --max-entries N retains newest N per namespace (LRU by mtime)
# ─────────────────────────────────────────────────────────────────────────────
rm -rf "$ZBUILD_PLAN_CONTEXT_DIR"
_write_ctx "repoA" "issue-200" "h_newest" "complete" 1
_write_ctx "repoA" "issue-200" "h_mid"    "complete" 5
_write_ctx "repoA" "issue-200" "h_oldest" "complete" 10
# A scope_too_large among the "oldest beyond N" must survive --max-entries: it
# is always retained and never counts toward the deletable budget (mirrors
# plan_context_gc). Make it the OLDEST so it would be pruned if status-blind.
_write_ctx "repoA" "issue-200" "h_old_stl" "scope_too_large" 20
# Keep newest 1; --older-than huge so age filter never fires (isolate LRU).
bash "$CLEANUP" --older-than 9999d --max-entries 1 --force >/dev/null 2>&1
ns="$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-200"
if [[ -f "$ns/h_newest.json" ]]; then
    assert_pass "[SPEC-6] --max-entries keeps newest"
else
    assert_fail "[SPEC-6] --max-entries keeps newest"
fi
if [[ ! -f "$ns/h_mid.json" && ! -f "$ns/h_oldest.json" ]]; then
    assert_pass "[SPEC-6] --max-entries deletes older entries"
else
    assert_fail "[SPEC-6] --max-entries deletes older entries" "mid/oldest still present"
fi
if [[ -f "$ns/h_old_stl.json" ]]; then
    assert_pass "[SPEC-6] --max-entries never deletes scope_too_large (resumable)"
else
    assert_fail "[SPEC-6] --max-entries never deletes scope_too_large (resumable)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-6] refuses a crafted out-of-root path (no deletion, clear refusal)
# ─────────────────────────────────────────────────────────────────────────────
# A symlink inside the cache pointing OUT must not let deletion escape the root.
reset_cache
victim_dir="$TEST_TEMP_DIR/outside"
mkdir -p "$victim_dir"
echo "do-not-delete" > "$victim_dir/precious.txt"
# Point the cache dir at a symlink whose target is outside the declared root,
# then ask the tool to wipe — the canonicalized path falls outside and is refused.
export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/evil-link"
ln -s "$victim_dir" "$ZBUILD_PLAN_CONTEXT_DIR"
out="$(bash "$CLEANUP" --all --force 2>&1 || true)"
if [[ -f "$victim_dir/precious.txt" ]]; then
    assert_pass "[SPEC-6] refuses symlink-escape; precious file survives"
else
    assert_fail "[SPEC-6] refuses symlink-escape; precious file survives" "got: $out"
fi
# Restore real cache dir for remaining tests.
rm -f "$ZBUILD_PLAN_CONTEXT_DIR"
export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/plan-context"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-6] state dirs are OUT OF SCOPE here — `zbuild cleanup --state-dirs` owns
# job-folder reclamation (#1920). The loop this replaces aged run dirs on mtime
# alone, with no in_progress / resume / unknown-status guard at all, so the
# harshest invocation the CLI accepts must now leave every run dir standing.
# ─────────────────────────────────────────────────────────────────────────────
runs_dir="$ZBUILD_STATE_DIR/runs"
mkdir -p "$runs_dir/active-run" "$runs_dir/stale-run"
_set_age_days "$runs_dir/active-run" 30
_set_age_days "$runs_dir/stale-run" 30
ZBUILD_RUN_ID="active-run" bash "$CLEANUP" --older-than 0d --force >/dev/null 2>&1
if [[ -d "$runs_dir/active-run" ]]; then
    assert_pass "[SPEC-6] active run dir is never deleted"
else
    assert_fail "[SPEC-6] active run dir is never deleted"
fi
if [[ -d "$runs_dir/stale-run" ]]; then
    assert_pass "[SPEC-6] stale run dir survives — state dirs are not this script's store"
else
    assert_fail "[SPEC-6] stale run dir survives — state dirs are not this script's store" \
        "cleanup-artifacts.sh deleted a job folder; that belongs to zbuild cleanup --state-dirs"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-6] --older-than respects mtime/created_at
# ─────────────────────────────────────────────────────────────────────────────
reset_cache
# With a 14d window, the 30d-old complete is stale but the 1d-old is fresh.
bash "$CLEANUP" --older-than 14d --status complete --force >/dev/null 2>&1
if [[ ! -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-100/h_old_complete.json" ]]; then
    assert_pass "[SPEC-6] --older-than 14d prunes the 30d-old complete"
else
    assert_fail "[SPEC-6] --older-than 14d prunes the 30d-old complete"
fi
if [[ -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-100/h_recent_complete.json" ]]; then
    assert_pass "[SPEC-6] --older-than 14d keeps the 1d-old complete"
else
    assert_fail "[SPEC-6] --older-than 14d keeps the 1d-old complete"
fi

# [SPEC-6] created_at is honored INDEPENDENTLY of mtime. A leaf whose mtime is
# FRESH but whose created_at is 30d old must still be pruned by --older-than 14d
# (age_epoch prefers created_at). Guards the BSD date-parse: a doubled-Z parse
# failure would silently fall back to the fresh mtime and skip the prune.
rm -rf "$ZBUILD_PLAN_CONTEXT_DIR"
_write_ctx "repoA" "issue-300" "h_oldcreate_freshmtime" "complete" 30
touch "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-300/h_oldcreate_freshmtime.json" \
      "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-300/h_oldcreate_freshmtime.md"
bash "$CLEANUP" --older-than 14d --status complete --force >/dev/null 2>&1
if [[ ! -f "$ZBUILD_PLAN_CONTEXT_DIR/repoA/issue-300/h_oldcreate_freshmtime.json" ]]; then
    assert_pass "[SPEC-6] created_at (30d) prunes despite fresh mtime"
else
    assert_fail "[SPEC-6] created_at (30d) prunes despite fresh mtime" "parse fell back to mtime?"
fi

print_test_results
