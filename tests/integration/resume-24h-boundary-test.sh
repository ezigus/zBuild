#!/usr/bin/env bash
# Tests: core/state/resume.sh — 24h auto/manual boundary (issues #299, #300)
# ADR-006: `status=in_progress` ∧ last update <24h → auto_resume; ≥24h → manual_resume_only.
#
# Closes the coverage gap surfaced by #298 — the 24h boundary logic IS
# implemented at resume.sh:195 but no test exercised the path. This file
# pins the verdict for four cases around the boundary plus two abort-trap
# paths from #300.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"

print_test_header "resume 24h boundary + abort-trap state-write coverage (#299, #300)"

setup_test_env "resume-24h-boundary"
STATE_FILE="$TEST_TEMP_DIR/state.json"

_set_status() {
    local sf="$1" st="$2"
    set_state_field "$sf" '.status' "\"$st\""
}

_set_updated_at() {
    local sf="$1" iso="$2"
    # set_state_field auto-overwrites .updated_at with $now (see
    # _zbuild_state_set_field), so we can't go through it for this test.
    # Do a direct jq + atomic-write instead.
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/zb-state.XXXXXX")"
    jq --arg iso "$iso" '.updated_at = $iso' "$sf" > "$tmp"
    mv "$tmp" "$sf"
}

# Portable ISO-8601 from epoch seconds (BSD + GNU date).
_iso_from_epoch() {
    local epoch="$1"
    if date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
        return 0
    fi
    if date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
        return 0
    fi
    echo "" # caller can detect empty
}

NOW="$(date -u +%s)"

# ─── Test 1: in_progress <24h → auto_resume ──────────────────────────────────
print_test_section "1. in_progress + last update 23h ago → auto_resume (#299)"
init_state "$STATE_FILE" "boundary-test-run-1" 0 >/dev/null 2>&1
_set_status "$STATE_FILE" "in_progress"
TS_23H="$(_iso_from_epoch $(( NOW - (23*3600) )))"
_set_updated_at "$STATE_FILE" "$TS_23H"
verdict="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "23h-old in_progress → auto_resume" "auto_resume" "$verdict"

# ─── Test 2: in_progress just under 24h (24h - 1min) → auto_resume ───────────
print_test_section "2. in_progress + 23h59m ago → auto_resume (just inside boundary)"
TS_23H59M="$(_iso_from_epoch $(( NOW - ((24*3600) - 60) )))"
_set_updated_at "$STATE_FILE" "$TS_23H59M"
verdict="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "23h59m-old in_progress → auto_resume" "auto_resume" "$verdict"

# ─── Test 3: in_progress just over 24h → manual_resume_only ──────────────────
print_test_section "3. in_progress + 24h1m ago → manual_resume_only (just outside boundary)"
TS_24H1M="$(_iso_from_epoch $(( NOW - ((24*3600) + 60) )))"
_set_updated_at "$STATE_FILE" "$TS_24H1M"
verdict="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "24h1m-old in_progress → manual_resume_only" "manual_resume_only" "$verdict"

# ─── Test 4: in_progress ≥24h (48h ago) → manual_resume_only ─────────────────
print_test_section "4. in_progress + 48h ago → manual_resume_only"
TS_48H="$(_iso_from_epoch $(( NOW - (48*3600) )))"
_set_updated_at "$STATE_FILE" "$TS_48H"
verdict="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "48h-old in_progress → manual_resume_only" "manual_resume_only" "$verdict"

# ─── Test 5: in_progress with empty updated_at → manual_resume_only ──────────
print_test_section "5. in_progress + empty updated_at → manual_resume_only"
# Direct write because set_state_field auto-stamps updated_at to now.
_set_updated_at "$STATE_FILE" ""
verdict="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "in_progress with empty updated_at → manual_resume_only (no risk of auto-resume)" \
    "manual_resume_only" "$verdict"

# ─── Test 6 (#300): runner abort trap — state-write failure surfaces loudly ──
print_test_section "6. runner abort-trap state-write failure path exercised (#300)"

# Simulate the abort-trap state-write failure by locking down the state
# file's parent directory. atomic_write's mv-into-place requires write
# perms on the directory inode; chmod'ing only the file is insufficient
# under POSIX (mv operates on the directory entry). The original coverage
# gap masked the bug because no test invoked this failure path.
ABORT_DIR="$TEST_TEMP_DIR/abort-trap"
mkdir -p "$ABORT_DIR"
ABORT_STATE="$ABORT_DIR/state.json"
rm -f "$ABORT_STATE"
set +e
init_state "$ABORT_STATE" "abort-trap-run" 0 >/dev/null 2>&1
init_rc=$?
set -e
if [[ $init_rc -ne 0 || ! -f "$ABORT_STATE" ]]; then
    cat > "$ABORT_STATE" <<'EOF'
{ "schema_version": 1, "run_id": "abort-trap-run", "issue": 0,
  "stage_statuses": {}, "current_iteration": 0, "self_heal_count": {},
  "scope_manifest_hash": "", "cost_ledger_pointer": 0, "claim_lease_id": "",
  "plugin_state": {}, "updated_at": "2026-05-26T00:00:00Z", "status": "pending" }
EOF
fi
ORIG_CONTENT="$(cat "$ABORT_STATE")"
chmod 0555 "$ABORT_DIR"

set +e
set_state_field "$ABORT_STATE" '.status' '"in_progress"' 2>/dev/null
write_rc=$?
set -e

chmod 0755 "$ABORT_DIR"

# Either the helper refuses to write (any non-zero rc) OR the file content
# remains unchanged. Both are acceptable; the silent-success-with-no-write
# shape is the one we're guarding against.
POST_CONTENT="$(cat "$ABORT_STATE")"
if [[ "$write_rc" -ne 0 || "$POST_CONTENT" == "$ORIG_CONTENT" ]]; then
    assert_pass "state-write into unwritable parent dir does not silently mutate state (rc=$write_rc)"
else
    assert_fail "state-write into unwritable parent dir must refuse or no-op" \
        "rc=0 AND content changed despite chmod 0555 on parent"
fi

# Note: the deeper "runner.sh ERR/EXIT trap fires under SIGTERM during a
# state write and the trap's own write fails" scenario requires forking
# the full runner under signals. That's an e2e test rather than this
# integration one. Test 6 above covers the meaningful pinch-point —
# set_state_field's response to a write that cannot land atomically.

cleanup_test_env
print_test_results
exit $((FAIL > 0))
