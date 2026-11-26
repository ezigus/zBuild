#!/usr/bin/env bash
# Tests: claim heartbeat defaults and cross-machine staleness (ADR-005 §3, #2533).
# Covers: DSHBT-3, DSHBT-4, DSHBT-5, DSHBT-6, DSHBT-7, DSHBT-8, DSHBT-12, DSHBT-15, DSHBT-16
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "claim heartbeat defaults and cross-machine staleness (ADR-005 §3, #2533)"
setup_test_env "claim-heartbeat-stale"
unset NO_GITHUB GITHUB_ACTIONS
# Never real GitHub: a gh that refuses, first on PATH (the takeover's own calls are stubbed below).
mkdir -p "$TEST_TEMP_DIR/bin"; printf '#!/usr/bin/env bash\necho "fake gh: unexpected call: $*" >&2; exit 1\n' > "$TEST_TEMP_DIR/bin/gh"
chmod +x "$TEST_TEMP_DIR/bin/gh"; export PATH="$TEST_TEMP_DIR/bin:$PATH"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_ZBUILD_ROOT="$REPO_ROOT"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

# Source run-status-comment.sh so its loaded guard fires; this gives us
# _rsc_epoch_to for timestamp math and sets _ZBUILD_RUN_STATUS_COMMENT_LOADED=1,
# which prevents the lazy source inside zbuild_claim_acquire from loading the
# real file and overriding our mock functions below.
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh" 2>/dev/null || true

# shellcheck source=../../core/claim/claim.sh
source "$REPO_ROOT/core/claim/claim.sh"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE"
CALLS="$TEST_TEMP_DIR/hook-calls"
export ZBUILD_RUN_ID="run-hb-1" ZBUILD_CLAIM_MACHINE_ID="box-hb"

# ─── Shared test helpers ─────────────────────────────────────────────────────

# _stub <root> <claim-reply> [claim-rc] [release-rc]
_stub() {
    local root="$1" dir="$1/claim-coordinator/stub"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/reply"
    cat > "$dir/manifest.yaml" <<EOF
id: claim-coordinator-stub
name: Stub claim coordinator
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: stub_claim
  release: stub_release
  heartbeat: stub_heartbeat
  list_claims: stub_list
provides:
  role: claim-coordinator
  alias: stub
EOF
    cat > "$dir/plugin.sh" <<EOF
stub_claim()   { printf 'claim %s\n'   "\$1" >> "$CALLS"; cat "$dir/reply"; return ${3:-0}; }
stub_release() { printf 'release %s\n' "\$1" >> "$CALLS"; return ${4:-0}; }
stub_heartbeat() { return 0; }
stub_list()    { printf '[]\n'; }
EOF
    export ZBUILD_PLUGINS_ROOT="$root"
    : > "$CALLS"; : > "$ZBUILD_EVENTS_JSONL"
    _ZBUILD_CLAIM_ACQUIRED=""
}

# _ci_holder <url> — a cross-machine CI holder (non-local format, never cleared by kill-0)
_ci_holder() { printf 'https://github.com/o/r/actions/runs/%s' "${1:-42}"; }

# _acq — call zbuild_claim_acquire, capture rc and combined output (stdout+stderr)
# Runs zbuild_claim_acquire in the current shell (not a subshell) so globals like
# _ZBUILD_CLAIM_ACQUIRED are properly set, while still capturing all output.
_acq() {
    _ACQ_RC=0
    zbuild_claim_acquire "$1" "$STATE" >"$TEST_TEMP_DIR/acq-out.txt" 2>&1 || _ACQ_RC=$?
    _ACQ_OUTPUT="$(cat "$TEST_TEMP_DIR/acq-out.txt" 2>/dev/null)"
}

# _epoch_to_iso <epoch> — portable ISO8601 conversion
_epoch_to_iso() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || printf '2020-01-01T00:00:00Z'
}
# _ts_ago <seconds> — ISO8601 timestamp N seconds in the past
_ts_ago() { _epoch_to_iso $(( $(date +%s) - $1 )); }  # determinism-ok: constructs test-data timestamp relative to now, not measuring elapsed time

# _mock_reset — reset mock state between sections
_mock_reset() {
    _MOCK_HB_CALLED=0
    _MOCK_LABEL_CALLED=0
    _MOCK_TAKEOVER_CALLED=0
    _MOCK_HB_TS=""
    _MOCK_LABEL_TS=""
    _MOCK_TAKEOVER_ARGS=""
}

# Install mock functions; claim.sh's lazy source is blocked by the loaded guard
# set above. These overrides are what zbuild_claim_acquire will find.
_mock_reset
rsc_heartbeat_find()     { _MOCK_HB_CALLED=1;      printf '%s' "$_MOCK_HB_TS";    return 0; }
rsc_label_added_at()     { _MOCK_LABEL_CALLED=1;    printf '%s' "$_MOCK_LABEL_TS"; return 0; }
# Capture all args so tests can verify rsc_takeover_note_post is called with the right holder
rsc_takeover_note_post() { _MOCK_TAKEOVER_CALLED=1; _MOCK_TAKEOVER_ARGS="$*"; return 0; }
# #2533 review: the first takeover note for the holder is this run's (the race
# is tests/unit/claim-takeover-real-test.sh TR3).
rsc_takeover_first_v() { local -n _m="$1"; _zbuild_claim_holder_v _m; return 0; }

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-7: ZBUILD_CLAIM_HEARTBEAT_S defaults to 600 when unset
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-7: ZBUILD_CLAIM_HEARTBEAT_S defaults to 600 when unset"

# Given: ZBUILD_CLAIM_HEARTBEAT_S is unset in the environment
# When: claim.sh is sourced
# Then: ZBUILD_CLAIM_HEARTBEAT_S is 600
hb_default=$(
    unset ZBUILD_CLAIM_HEARTBEAT_S
    unset _ZBUILD_CLAIM_SH_LOADED
    # shellcheck source=../../core/claim/claim.sh
    source "$REPO_ROOT/core/claim/claim.sh" 2>/dev/null
    printf '%s' "${ZBUILD_CLAIM_HEARTBEAT_S:-not_set}"
)
assert_eq "[DSHBT-7] ZBUILD_CLAIM_HEARTBEAT_S defaults to 600 when unset" "600" "$hb_default"
# Cleanup: nothing to restore (subshell)

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-8: ZBUILD_CLAIM_STALE_S defaults to 1800 when unset
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-8: ZBUILD_CLAIM_STALE_S defaults to 1800 when unset"

# Given: ZBUILD_CLAIM_STALE_S is unset in the environment
# When: claim.sh is sourced
# Then: ZBUILD_CLAIM_STALE_S is 1800
stale_default=$(
    unset ZBUILD_CLAIM_STALE_S
    unset _ZBUILD_CLAIM_SH_LOADED
    # shellcheck source=../../core/claim/claim.sh
    source "$REPO_ROOT/core/claim/claim.sh" 2>/dev/null
    printf '%s' "${ZBUILD_CLAIM_STALE_S:-not_set}"
)
assert_eq "[DSHBT-8] ZBUILD_CLAIM_STALE_S defaults to 1800 when unset" "1800" "$stale_default"
# Cleanup: nothing to restore (subshell)

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-6 (done): a local dead-pid claim is cleared without consulting a heartbeat
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-6 (done): local dead-pid claim cleared before any heartbeat check"

# Given: local holder on this machine with a dead PID
export ZBUILD_CLAIM_STALE_S=1800
_stale_local() {  # <root> <holder>
    local dir="$1/claim-coordinator/stub"
    _stub "$1" "$(jq -nc --arg h "$2" '{acquired:false, holder:$h}')"
    cat >> "$dir/plugin.sh" <<STUB
stub_claim() { printf 'claim %s\n' "\$1" >> "$CALLS"; cat "$dir/reply"; printf '{"acquired": true}' > "$dir/reply"; return 0; }
STUB
}
_stale_local "$TEST_TEMP_DIR/p-dead-local" \
    "run_id=old-run machine=box-hb pid=999999"
_mock_reset
# When: zbuild_claim_acquire is called
_acq 9100
# Then: cleared and re-acquired (rc=0)
assert_eq "[DSHBT-6] local dead-pid holder → cleared and re-acquired (rc=0)" "0" "$_ACQ_RC"
# And: rsc_heartbeat_find is NOT called (same-machine path runs first)
assert_eq "[DSHBT-6] rsc_heartbeat_find is not consulted for a local dead-pid claim" \
    "0" "$_MOCK_HB_CALLED"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-12 (done): unclaimed issue acquired without consulting heartbeat
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-12 (done): unclaimed issue acquired without heartbeat"

# Given: coordinator returns acquired=true (unclaimed issue)
_stub "$TEST_TEMP_DIR/p-unclaimed" '{"acquired": true}'
_mock_reset
# When: zbuild_claim_acquire is called
_acq 9101
# Then: rc=0 (acquired)
assert_eq "[DSHBT-12] unclaimed issue → rc=0 (acquired)" "0" "$_ACQ_RC"
# And: rsc_heartbeat_find is NOT called
assert_eq "[DSHBT-12] rsc_heartbeat_find not called for an unclaimed issue" \
    "0" "$_MOCK_HB_CALLED"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-3: fresh heartbeat → refused, holder named, heartbeat consulted
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-3: fresh heartbeat → refused, holder named"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, heartbeat is fresh (< ZBUILD_CLAIM_STALE_S seconds old)
_stub "$TEST_TEMP_DIR/p-fresh-ci" \
    "$(jq -nc --arg h "$(_ci_holder 100)" '{acquired:false, holder:$h}')"
_mock_reset
_MOCK_HB_TS="$(_ts_ago $(( ZBUILD_CLAIM_STALE_S - 100 )))"
# When: zbuild_claim_acquire is called
_acq 9102
# Then: rc=1 (refused)
assert_eq "[DSHBT-3] fresh heartbeat (<ZBUILD_CLAIM_STALE_S) → refused (rc=1)" "1" "$_ACQ_RC"
# And: the heartbeat was consulted (rsc_heartbeat_find called)
assert_eq "[DSHBT-3] rsc_heartbeat_find was consulted for the cross-machine claim" \
    "1" "$_MOCK_HB_CALLED"
# And: the refusal output names the holder (SPEC requires printed message, not just internal var)
assert_contains "[DSHBT-3] refusal output names the holder" \
    "$_ACQ_OUTPUT" "$(_ci_holder 100)"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-4: stale heartbeat → take over, post note, acquire
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-4: stale heartbeat → takeover note posted, claim acquired"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, heartbeat is stale (>= ZBUILD_CLAIM_STALE_S seconds old)
# Coordinator returns acquired:false first, then acquired:true after re-claim
_stale_ci_stub() {  # <root> <holder>
    local dir="$1/claim-coordinator/stub"
    _stub "$1" "$(jq -nc --arg h "$2" '{acquired:false, holder:$h}')"
    cat >> "$dir/plugin.sh" <<STUB
stub_claim() { printf 'claim %s\n' "\$1" >> "$CALLS"; cat "$dir/reply"; printf '{"acquired": true}' > "$dir/reply"; return 0; }
STUB
}
_stale_ci_stub "$TEST_TEMP_DIR/p-stale-ci" "$(_ci_holder 101)"
_mock_reset
_MOCK_HB_TS="$(_ts_ago $(( ZBUILD_CLAIM_STALE_S + 100 )))"
# When: zbuild_claim_acquire is called
_acq 9103
# Then: a new comment is posted (takeover note), and it names the stale holder
assert_eq "[DSHBT-4] stale heartbeat → takeover note posted" "1" "$_MOCK_TAKEOVER_CALLED"
assert_contains "[DSHBT-4] takeover note is called with the stale holder" \
    "$_MOCK_TAKEOVER_ARGS" "$(_ci_holder 101)"
# And: the claim is acquired (rc=0)
assert_eq "[DSHBT-4] stale heartbeat → claim acquired (rc=0)" "0" "$_ACQ_RC"
# And: the claim is recorded as this run's
assert_eq "[DSHBT-4] stale takeover → _ZBUILD_CLAIM_ACQUIRED set" "9103" "$_ZBUILD_CLAIM_ACQUIRED"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-5: no heartbeat → use label-added timestamp; API error → refuse
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-5a: no heartbeat + stale label-added → rsc_label_added_at used, takeover"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, no heartbeat line, label-added timestamp is stale
_stale_ci_stub "$TEST_TEMP_DIR/p-no-hb-stale" "$(_ci_holder 102)"
_mock_reset
_MOCK_HB_TS=""   # no heartbeat
_MOCK_LABEL_TS="$(_ts_ago $(( ZBUILD_CLAIM_STALE_S + 100 )))"
# When: zbuild_claim_acquire is called
_acq 9104
# Then: rsc_label_added_at was consulted (not the heartbeat path)
assert_eq "[DSHBT-5] no heartbeat → rsc_label_added_at is consulted" \
    "1" "$_MOCK_LABEL_CALLED"
# And: the age comes from the label-added timestamp (stale → take over, rc=0)
assert_eq "[DSHBT-5] stale label-added timestamp → takeover (rc=0)" "0" "$_ACQ_RC"

print_test_section "DSHBT-5b: no heartbeat + label-added unavailable (API error) → refuse"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, no heartbeat, label-added timestamp unavailable
_stub "$TEST_TEMP_DIR/p-no-hb-err" \
    "$(jq -nc --arg h "$(_ci_holder 103)" '{acquired:false, holder:$h}')"
_mock_reset
_MOCK_HB_TS=""      # no heartbeat
_MOCK_LABEL_TS=""   # API error — empty means unknown
# When: zbuild_claim_acquire is called
_acq 9105
# Then: refuse (fail closed) rather than taking over
assert_eq "[DSHBT-5] label-added unavailable → refuse (rc=1, fail closed)" "1" "$_ACQ_RC"
# And: rsc_label_added_at was consulted even when it returns no timestamp
assert_eq "[DSHBT-5] label-added unavailable → rsc_label_added_at was consulted" \
    "1" "$_MOCK_LABEL_CALLED"

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-15: rsc_takeover_note_post non-zero → refuse, claim not acquired
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-15: rsc_takeover_note_post failure → refuse (rc=1)"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, heartbeat is stale (>= ZBUILD_CLAIM_STALE_S seconds old);
# rsc_takeover_note_post returns non-zero (GitHub API failure)
# Coordinator first returns acquired:false (triggering stale path), then true if retried
_stale_ci_stub "$TEST_TEMP_DIR/p-stale-note-fail" "$(_ci_holder 104)"
_mock_reset
_MOCK_HB_TS="$(_ts_ago $(( ZBUILD_CLAIM_STALE_S + 100 )))"
# Override the mock to return failure for this section
rsc_takeover_note_post() { _MOCK_TAKEOVER_CALLED=1; _MOCK_TAKEOVER_ARGS="$*"; return 1; }
# When: zbuild_claim_acquire calls rsc_takeover_note_post and it returns non-zero
_acq 9106
# Then: rsc_takeover_note_post was called (proves the stale path was reached)
assert_eq "[DSHBT-15] note-post failure → rsc_takeover_note_post was called" \
    "1" "$_MOCK_TAKEOVER_CALLED"
# Then: zbuild_claim_acquire returns 1 (refused)
assert_eq "[DSHBT-15] note-post failure → refused (rc=1)" "1" "$_ACQ_RC"
# And: the claim is not acquired (no acquisition even if coordinator would return true on retry)
assert_eq "[DSHBT-15] note-post failure → claim not acquired" "" "${_ZBUILD_CLAIM_ACQUIRED:-}"
# Cleanup: restore the mock to return 0 (default for other sections)
rsc_takeover_note_post() { _MOCK_TAKEOVER_CALLED=1; _MOCK_TAKEOVER_ARGS="$*"; return 0; }
# #2533 review: the first takeover note for the holder is this run's (the race
# is tests/unit/claim-takeover-real-test.sh TR3).
rsc_takeover_first_v() { local -n _m="$1"; _zbuild_claim_holder_v _m; return 0; }

# ═══════════════════════════════════════════════════════════════════════════
# DSHBT-16: stale takeover refused when run-status-comment.sh cannot be loaded
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "DSHBT-16a: stale takeover refused when run-status-comment.sh is absent"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, heartbeat is stale (>= ZBUILD_CLAIM_STALE_S);
# _ZBUILD_RUN_STATUS_COMMENT_LOADED is unset so the lazy source fires;
# run-status-comment.sh does not exist at the expected path under _ZBUILD_ROOT
_stub "$TEST_TEMP_DIR/p-rsc-absent" \
    "$(jq -nc --arg h "$(_ci_holder 105)" '{acquired:false, holder:$h}')"
_mock_reset
_MOCK_HB_TS="$(_ts_ago $(( ZBUILD_CLAIM_STALE_S + 100 )))"
_zb_root_saved="$_ZBUILD_ROOT"
_ZBUILD_ROOT="$TEST_TEMP_DIR/fake-root-absent"
mkdir -p "$_ZBUILD_ROOT/scripts/lib"
# Note: do NOT create run-status-comment.sh — intentionally absent
unset _ZBUILD_RUN_STATUS_COMMENT_LOADED
# When: zbuild_claim_acquire is called (lazy source fails to find the file)
_acq 9107
# Then: zbuild_claim_acquire returns 1 (refused)
assert_eq "[DSHBT-16] rsc absent → stale takeover refused (rc=1)" "1" "$_ACQ_RC"
# And: the claim is not acquired
assert_eq "[DSHBT-16] rsc absent → claim not acquired" "" "${_ZBUILD_CLAIM_ACQUIRED:-}"
# Cleanup: restore _ZBUILD_ROOT and re-establish the loaded guard
_ZBUILD_ROOT="$_zb_root_saved"
_ZBUILD_RUN_STATUS_COMMENT_LOADED=1

print_test_section "DSHBT-16b: stale takeover refused when rsc_takeover_note_post is not defined"
export ZBUILD_CLAIM_STALE_S=1800

# Given: CI holder, heartbeat is stale; run-status-comment.sh exists at _ZBUILD_ROOT
# but does NOT define rsc_takeover_note_post;
# _ZBUILD_RUN_STATUS_COMMENT_LOADED is unset so the lazy source fires
_stub "$TEST_TEMP_DIR/p-rsc-no-fn" \
    "$(jq -nc --arg h "$(_ci_holder 106)" '{acquired:false, holder:$h}')"
_mock_reset
_MOCK_HB_TS="$(_ts_ago $(( ZBUILD_CLAIM_STALE_S + 100 )))"
_zb_root_saved2="$_ZBUILD_ROOT"
_ZBUILD_ROOT="$TEST_TEMP_DIR/fake-root-no-fn"
mkdir -p "$_ZBUILD_ROOT/scripts/lib"
# Create a stub rsc file that sets a sentinel but does NOT define rsc_takeover_note_post
printf '#!/usr/bin/env bash\n# stub — deliberately omits rsc_takeover_note_post\n_ZBUILD_RUN_STATUS_COMMENT_LOADED=1\n_DSHBT16_STUB_SOURCED=1\n' \
    > "$_ZBUILD_ROOT/scripts/lib/run-status-comment.sh"
_DSHBT16_STUB_SOURCED=0
unset _ZBUILD_RUN_STATUS_COMMENT_LOADED
# Remove the in-process mock so declare -F rsc_takeover_note_post also fails after sourcing
unset -f rsc_takeover_note_post
# When: zbuild_claim_acquire is called (lazy source loads stub; function not defined)
_acq 9108
# Then: the stub was sourced by the lazy load (new code enters this path; base code never does)
assert_eq "[DSHBT-16] rsc_takeover_note_post not defined → stub file was sourced" \
    "1" "$_DSHBT16_STUB_SOURCED"
# Then: zbuild_claim_acquire returns 1 (refused)
assert_eq "[DSHBT-16] rsc_takeover_note_post not defined → stale takeover refused (rc=1)" \
    "1" "$_ACQ_RC"
# And: the claim is not acquired
assert_eq "[DSHBT-16] rsc_takeover_note_post not defined → claim not acquired" \
    "" "${_ZBUILD_CLAIM_ACQUIRED:-}"
# Cleanup: restore _ZBUILD_ROOT, re-establish guard, restore mock
_ZBUILD_ROOT="$_zb_root_saved2"
_ZBUILD_RUN_STATUS_COMMENT_LOADED=1
rsc_takeover_note_post() { _MOCK_TAKEOVER_CALLED=1; _MOCK_TAKEOVER_ARGS="$*"; return 0; }
# #2533 review: the first takeover note for the holder is this run's (the race
# is tests/unit/claim-takeover-real-test.sh TR3).
rsc_takeover_first_v() { local -n _m="$1"; _zbuild_claim_holder_v _m; return 0; }

# Cleanup
unset ZBUILD_CLAIM_STALE_S
cleanup_test_env
print_test_results
exit $((FAIL > 0))
