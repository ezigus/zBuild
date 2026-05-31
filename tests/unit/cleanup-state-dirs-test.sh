#!/usr/bin/env bash
# Tests: scripts/lib/cleanup.sh — state-file scanner + prune decisions (#570)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup state-dir scanner (#570)"
setup_test_env "cleanup-state-dirs"

# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR"

_write_state_file() {
    local name="$1" status="$2" age_days="$3"
    local path="$STATE_DIR/$name"
    jq -n --arg s "$status" --arg id "${name%.json}" \
        '{schema_version:1, run_id:$id, issue:1, status:$s, stage_statuses:{}, current_iteration:0, self_heal_count:{}, updated_at:"2026-01-01T00:00:00.000Z"}' \
        > "$path"
    if [[ "$age_days" -gt 0 ]]; then
        # Set mtime to N days ago.
        local secs=$(( age_days * 86400 ))
        # touch -d portable: BSD uses -t, GNU uses -d
        if touch -d "@$(( $(date +%s) - secs ))" "$path" 2>/dev/null; then
            :
        else
            # BSD touch
            local ts; ts="$(date -r $(( $(date +%s) - secs )) "+%Y%m%d%H%M.%S")"
            touch -t "$ts" "$path"
        fi
    fi
}

_write_state_file "pipeline-state.json" "complete" 30
_write_state_file "pipeline-state-recent.json" "complete" 1
_write_state_file "pipeline-state-failed.json" "failed" 30
_write_state_file "pipeline-state-running.json" "in_progress" 30
_write_state_file "pipeline-state-interrupted.json" "interrupted" 30
_write_state_file "pipeline-state-aborted.json" "aborted" 30

# ── TC-1: scan with age_days=14 — recent file not pruned ─────────────────────
out="$(_cleanup_scan_state_files "$STATE_DIR" 14 false)"
if grep -q "pipeline-state.json" <<<"$out"; then
    assert_pass "old complete file is candidate"
else
    assert_fail "old complete file is candidate" "got: $out"
fi
if grep -q "pipeline-state-recent.json" <<<"$out"; then
    assert_fail "recent file should NOT be candidate" "got: $out"
else
    assert_pass "recent file is skipped (age)"
fi

# ── TC-2: failed/aborted old files are candidates ────────────────────────────
if grep -q "pipeline-state-failed.json" <<<"$out"; then
    assert_pass "failed file is candidate"
else
    assert_fail "failed file is candidate" "got: $out"
fi
if grep -q "pipeline-state-aborted.json" <<<"$out"; then
    assert_pass "aborted file is candidate"
else
    assert_fail "aborted file is candidate" "got: $out"
fi

# ── TC-3: in_progress always skipped ─────────────────────────────────────────
if grep -q "pipeline-state-running.json" <<<"$out"; then
    assert_fail "in_progress NEVER candidate" "got: $out"
else
    assert_pass "in_progress skipped without --force"
fi

# ── TC-4: interrupted skipped without --force ────────────────────────────────
if grep -q "pipeline-state-interrupted.json" <<<"$out"; then
    assert_fail "interrupted skipped without --force" "got: $out"
else
    assert_pass "interrupted skipped without --force"
fi

# ── TC-5: interrupted prunable with --force ──────────────────────────────────
out_force="$(_cleanup_scan_state_files "$STATE_DIR" 14 true)"
if grep -q "pipeline-state-interrupted.json" <<<"$out_force"; then
    assert_pass "interrupted candidate with --force"
else
    assert_fail "interrupted candidate with --force" "got: $out_force"
fi

# ── TC-6: in_progress STILL skipped even with --force (fail-CLOSED) ──────────
if grep -q "pipeline-state-running.json" <<<"$out_force"; then
    assert_fail "in_progress NEVER pruned even with --force" "got: $out_force"
else
    assert_pass "in_progress NEVER pruned (fail-CLOSED)"
fi

# ── TC-7: dry-run does NOT delete files ──────────────────────────────────────
# Run _cleanup_apply_plan in dry-run mode and assert files survive
candidates="$(_cleanup_scan_state_files "$STATE_DIR" 14 false)"
_cleanup_apply_plan "$candidates" true >/dev/null 2>&1 || true
if [[ -f "$STATE_DIR/pipeline-state.json" ]]; then
    assert_pass "dry-run preserves files"
else
    assert_fail "dry-run preserves files"
fi

# ── TC-8: apply mode actually deletes ────────────────────────────────────────
# Recreate file before pruning
_write_state_file "pipeline-state.json" "complete" 30
candidates="$(_cleanup_scan_state_files "$STATE_DIR" 14 false)"
_cleanup_apply_plan "$candidates" false >/dev/null 2>&1 || true
if [[ ! -f "$STATE_DIR/pipeline-state.json" ]]; then
    assert_pass "apply mode deletes pruned files"
else
    assert_fail "apply mode deletes pruned files"
fi

print_test_results
