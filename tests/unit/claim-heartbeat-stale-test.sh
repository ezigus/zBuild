#!/usr/bin/env bash
# Tests: claim heartbeat defaults and cross-machine staleness (ADR-005 §3, #2533).
# Covers: DSHBT-6, DSHBT-7, DSHBT-8, DSHBT-12 (the takeover itself: claim-takeover-real-test.sh)
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

# _acq — call zbuild_claim_acquire in this shell (so _ZBUILD_CLAIM_ACQUIRED is
# set), capturing its rc and its output.
_acq() {
    _ACQ_RC=0
    zbuild_claim_acquire "$1" "$STATE" >"$TEST_TEMP_DIR/acq-out.txt" 2>&1 || _ACQ_RC=$?
    _ACQ_OUTPUT="$(cat "$TEST_TEMP_DIR/acq-out.txt" 2>/dev/null)"
}

# _mock_reset — reset mock state between sections
_mock_reset() {
    _MOCK_HB_CALLED=0
    _MOCK_LABEL_CALLED=0
    _MOCK_TAKEOVER_CALLED=0
    _MOCK_HB_TS=""
    _MOCK_LABEL_TS=""
    _MOCK_TAKEOVER_ARGS=""
}

# A spy on the takeover's first read: the same-machine and unclaimed paths
# never reach it. claim-takeover.sh is not loaded while claim_age_v is defined.
_mock_reset
claim_age_v() { _MOCK_HB_CALLED=1; return 1; }

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
# And: the takeover read is not made (the same-machine path runs first)
assert_eq "[DSHBT-6] the takeover read is not made for a local dead-pid claim" \
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
# And: the takeover read is not made
assert_eq "[DSHBT-12] the takeover read is not made for an unclaimed issue" \
    "0" "$_MOCK_HB_CALLED"

# DSHBT-3, DSHBT-4, DSHBT-5, DSHBT-15, DSHBT-16: the takeover, end to end with
# only gh faked — tests/unit/claim-takeover-real-test.sh (#2533 review).

# Cleanup
unset ZBUILD_CLAIM_STALE_S
cleanup_test_env
print_test_results
exit $((FAIL > 0))
