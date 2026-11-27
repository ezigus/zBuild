#!/usr/bin/env bash
# Tests: core/claim/claim.sh — the engine's side of the cross-machine claim
# (ADR-005 §1, §3). The coordinator is a stub plugin under the plugins root;
# what the engine does with each answer is what is under test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../lib/claim-gh-mock.sh
source "$REPO_ROOT/tests/lib/claim-gh-mock.sh"

print_test_header "core/claim: claim and release through the coordinator (ADR-005)"
setup_test_env "claim-acquire-release"
unset NO_GITHUB GITHUB_ACTIONS
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
export ZBUILD_RUN_ID="run-cl-1" ZBUILD_CLAIM_MACHINE_ID="box-1"

# _stub <root> <claim reply> [claim rc] [release rc] — a claim coordinator that
# logs each hook call ("claim <issue>", "release <issue>") to $CALLS.
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
stub_claim() { printf 'claim %s\n' "\$1" >> "$CALLS"; cat "$dir/reply"; return ${3:-0}; }
stub_release() { printf 'release %s\n' "\$1" >> "$CALLS"; return ${4:-0}; }
stub_heartbeat() { return 0; }
stub_list() { printf '[]\n'; }
EOF
    export ZBUILD_PLUGINS_ROOT="$root"
    : > "$CALLS"; : > "$ZBUILD_EVENTS_JSONL"
    _ZBUILD_CLAIM_ACQUIRED=""
}
_event() { jq -c --arg t "$1" 'select(.type == $t) | .data' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true; }
_acq() { _ACQ_RC=0; zbuild_claim_acquire "$1" "$STATE" 2>"$TEST_TEMP_DIR/acq.err" || _ACQ_RC=$?; }

print_test_section "a run with no issue makes no claim"
_stub "$TEST_TEMP_DIR/p-goal" '{"acquired": true}'
_acq ""; assert_eq "no issue → rc 0" "0" "$_ACQ_RC"
_acq "0"; assert_eq "issue 0 → rc 0" "0" "$_ACQ_RC"
assert_eq "…and the coordinator is never called" "" "$(cat "$CALLS")"

print_test_section "the coordinator is looked up under the plugins root only"
mkdir -p "$TEST_TEMP_DIR/p-empty/tool/nothing"
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/p-empty"; : > "$ZBUILD_EVENTS_JSONL"
GHS="$TEST_TEMP_DIR/gh"; claim_gh_mock_install "$GHS"; : > "$GHS/repo-label"
_acq 9001
assert_eq "no coordinator under the root → rc 0 (the run goes on)" "0" "$_ACQ_RC"
assert_eq "…the engine's own github-labels plugin is not used instead (no gh call)" "0" "$(wc -l < "$GHS/log" | tr -d ' ')"
assert_contains "…and the skip is an event" "$(_event pipeline.claim.skipped)" "no claim-coordinator"

print_test_section "claimed: the run has it, and says who it is"
_stub "$TEST_TEMP_DIR/p-ok" '{"acquired": true}'
_acq 9002
assert_eq "acquired → rc 0" "0" "$_ACQ_RC"
assert_eq "the claim hook was called once with the issue" "claim 9002" "$(cat "$CALLS")"
assert_eq "the claim hook's events carry no stage (the issue is not one)" "0" \
    "$(jq -c 'select((.type | startswith("plugin.claim.")) and has("stage"))' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')"
assert_eq "pipeline.claim.acquired names the holder: run id and machine" \
    "run_id=run-cl-1 machine=box-1 pid=$$" "$(_event pipeline.claim.acquired | jq -r .holder)"
_stub "$TEST_TEMP_DIR/p-ok" '{"acquired": true}'
GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=77 _acq 9003
assert_eq "in CI the holder is the CI run's URL" "https://github.com/o/r/actions/runs/77" \
    "$(_event pipeline.claim.acquired | jq -r .holder)"

print_test_section "refused: another run holds it"
_stub "$TEST_TEMP_DIR/p-ref" "$(jq -nc --arg h "$(printf 'run_id=r9 machine=\033[31mbox\033[0m\tx\001')" '{acquired:false, holder:$h}')"
_acq 9004
assert_eq "refused → rc 1" "1" "$_ACQ_RC"
assert_eq "the holder is kept with every control character taken out" \
    "run_id=r9 machine=[31mbox[0mx" "$_ZBUILD_CLAIM_THEIR_HOLDER"
assert_eq "no claim is recorded as this run's" "" "$_ZBUILD_CLAIM_ACQUIRED"

print_test_section "an answer the engine cannot read is a refusal (a label may be there)"
_stub "$TEST_TEMP_DIR/p-bad" 'acquired? who knows'
_acq 9005
assert_eq "unreadable reply → rc 1" "1" "$_ACQ_RC"

print_test_section "the coordinator fails or skips: the run goes on, and says so"
_stub "$TEST_TEMP_DIR/p-err" '{"acquired": false, "reason": "backend_error"}' 1
_acq 9006
assert_eq "hook rc 1 → rc 0" "0" "$_ACQ_RC"
assert_contains "…pipeline.claim.skipped is emitted" "$(_event pipeline.claim.skipped)" '"issue":"9006"'
_stub "$TEST_TEMP_DIR/p-skip" '{"acquired": false, "skipped": "NO_GITHUB=true"}'
_acq 9007
assert_eq "skipped reply → rc 0" "0" "$_ACQ_RC"
assert_contains "…pipeline.claim.skipped carries the coordinator's reason" "$(_event pipeline.claim.skipped)" "NO_GITHUB=true"

print_test_section "the hook said it acquired, then ended badly: the claim is held (#2586 R6)"
# C7's failure: the hook's reply says acquired, but its status reads non-zero
# (an interrupt cut the wait short). The label is on the issue: the run must
# hold the claim, so that its exit releases it.
_stub "$TEST_TEMP_DIR/p-acq-rc" '{"acquired": true}' 143
_acq 9010
assert_eq "an acquired reply with a bad status → the claim is held" "9010" "$_ZBUILD_CLAIM_ACQUIRED"
: > "$CALLS"; zbuild_claim_release
assert_eq "…and released at the end" "release 9010" "$(cat "$CALLS")"

print_test_section "a stale claim this machine left is cleared at start (#2589)"
# The coordinator refuses for run old-run on this machine (box-1), then claims.
_stale_stub() {  # <root> <holder>
    local dir="$1/claim-coordinator/stub"
    _stub "$1" "$(jq -nc --arg h "$2" '{acquired:false, holder:$h}')"
    cat >> "$dir/plugin.sh" <<STUB
stub_claim() { printf 'claim %s\n' "\$1" >> "$CALLS"; cat "$dir/reply"; printf '{"acquired": true}' > "$dir/reply"; return 0; }
STUB
}
_stale_stub "$TEST_TEMP_DIR/p-stale" "run_id=old-run machine=box-1 pid=999999"
_acq 9011
assert_eq "[S1] this machine's dead run held it: cleared, then claimed" "0" "$_ACQ_RC"
assert_eq "[S1] ...claim, release, claim" "$(printf 'claim 9011\nrelease 9011\nclaim 9011')" "$(cat "$CALLS")"
assert_contains "[S1] ...and says so" "$(_event pipeline.claim.stale_cleared)" '"holder":"run_id=old-run machine=box-1 pid=999999"'
_stale_stub "$TEST_TEMP_DIR/p-other" "run_id=old-run machine=box-2 pid=999999"
_acq 9012
assert_eq "[S2] another machine's claim is left: refused" "1" "$_ACQ_RC"
assert_eq "[S2] ...one claim, no release" "claim 9012" "$(cat "$CALLS")"
_stale_stub "$TEST_TEMP_DIR/p-alive" "run_id=live-run machine=box-1 pid=$$"
_acq 9013
assert_eq "[S3] this machine's run still alive (its pid answers): refused" "1" "$_ACQ_RC"
assert_eq "[S3] ...one claim, no release" "claim 9013" "$(cat "$CALLS")"
# S4 (review of #2589): a resumed run finds its own claim: it holds it again.
_stale_stub "$TEST_TEMP_DIR/p-mine" "run_id=run-cl-1 machine=box-1 pid=1"
_acq 9014
assert_eq "[S4] this run's own claim (a resume): held, not refused" "0" "$_ACQ_RC"
assert_eq "[S4] ...held as this run's" "9014" "$_ZBUILD_CLAIM_ACQUIRED"
assert_eq "[S4] ...one claim, no release" "claim 9014" "$(cat "$CALLS")"

print_test_section "release"
_stub "$TEST_TEMP_DIR/p-rel" '{"acquired": true}'
zbuild_claim_release
assert_eq "no claim held → the release hook is not called" "" "$(cat "$CALLS")"
_acq 9008; : > "$CALLS"
ZBUILD_CURRENT_STAGE=build zbuild_claim_release; zbuild_claim_release
assert_eq "a held claim is released once, on its issue" "release 9008" "$(cat "$CALLS")"
assert_eq "…its events carry no stage, not even the one the run was in" "0" \
    "$(jq -c 'select((.type | startswith("plugin.release.")) and has("stage"))' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')"
_stub "$TEST_TEMP_DIR/p-relfail" '{"acquired": true}' 0 1
_acq 9009
set +e; zbuild_claim_release 2>/dev/null; rc=$?; set -e
assert_eq "a failed release never fails the caller" "0" "$rc"
assert_contains "…and is an event" "$(_event pipeline.claim.release_failed)" '"issue":"9009"'

# ─── DSRACE-4,5: race_lost: true in the coordinator reply ─────────────────────
# The coordinator returns {"acquired": false, "holder": "<winner>", "race_lost": true}.
# zbuild_claim_acquire must:
#   DSRACE-5: refuse immediately (rc 1), skip stale-takeover, name winner on stderr
#   DSRACE-4: NOT set _ZBUILD_CLAIM_ACQUIRED; zbuild_claim_release must NOT call release

# _stub_with_takeover <root> <claim_reply> — like _stub but also registers a
# takeover hook that logs calls and returns a successful takeover JSON. Used to
# exercise the base code path where race_lost is not detected and takeover runs.
_stub_with_takeover() {
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
  takeover: stub_takeover
provides:
  role: claim-coordinator
  alias: stub
EOF
    cat > "$dir/plugin.sh" <<EOF
stub_claim()    { printf 'claim %s\n'    "\$1" >> "$CALLS"; cat "$dir/reply"; return 0; }
stub_release()  { printf 'release %s\n' "\$1" >> "$CALLS"; return 0; }
stub_heartbeat(){ return 0; }
stub_list()     { printf '[]\n'; }
stub_takeover() {
    printf 'takeover %s\n' "\$1" >> "$CALLS"
    printf '{"taken_over":true,"claimed":true,"age_s":999}'
}
EOF
    export ZBUILD_PLUGINS_ROOT="$root"
    : > "$CALLS"; : > "$ZBUILD_EVENTS_JSONL"
    _ZBUILD_CLAIM_ACQUIRED=""
}

print_test_section "race_lost: true — refused immediately, stale-takeover skipped [DSRACE-5]"
# Given: coordinator returns race_lost:true naming a concurrent winner; takeover
#        hook is registered and would succeed if called (on base code the takeover
#        path fires; on new code the race_lost early-return fires first)
_stub_with_takeover "$TEST_TEMP_DIR/p-race5" \
    '{"acquired": false, "holder": "https://github.com/o/r/actions/runs/42", "race_lost": true}'
# When
set +e; zbuild_claim_acquire 9050 "$STATE" 2>"$TEST_TEMP_DIR/race5.err"; _r5_rc=$?; set -e
assert_eq "[DSRACE-5] race_lost reply → rc 1 (immediate refusal)" "1" "$_r5_rc" # [DSRACE-5]
# Then: the stale-takeover hook is not called
_takeover_calls=0
grep -q '^takeover' "$CALLS" 2>/dev/null && _takeover_calls=1 || true
assert_eq "[DSRACE-5] stale-takeover hook was NOT called" "0" "$_takeover_calls" # [DSRACE-5]
# And: stderr names the concurrent winner as the first claimant
assert_contains "[DSRACE-5] stderr names the concurrent winner" \
    "$(cat "$TEST_TEMP_DIR/race5.err")" "https://github.com/o/r/actions/runs/42" # [DSRACE-5]
assert_contains "[DSRACE-5] stderr says 'concurrent claim'" \
    "$(cat "$TEST_TEMP_DIR/race5.err")" "concurrent claim" # [DSRACE-5]
assert_contains "[DSRACE-5] stderr names the winner as the first claimant" \
    "$(cat "$TEST_TEMP_DIR/race5.err")" "first" # [DSRACE-5]

print_test_section "race_lost: true — _ZBUILD_CLAIM_ACQUIRED not set, release skips label removal [DSRACE-4]"
# Given: coordinator returns race_lost:true; takeover hook is registered and would
#        succeed if called (on base code takeover sets _ZBUILD_CLAIM_ACQUIRED and
#        calls release; on new code the race_lost early-return fires before that)
_stub_with_takeover "$TEST_TEMP_DIR/p-race4" \
    '{"acquired": false, "holder": "https://github.com/o/r/actions/runs/77", "race_lost": true}'
# When
set +e; zbuild_claim_acquire 9051 "$STATE" 2>/dev/null; set -e
# Then: _ZBUILD_CLAIM_ACQUIRED is not set
assert_eq "[DSRACE-4] _ZBUILD_CLAIM_ACQUIRED is not set after race_lost" "" \
    "$_ZBUILD_CLAIM_ACQUIRED" # [DSRACE-4]
# And: zbuild_claim_release does not call the release hook
: > "$CALLS"
zbuild_claim_release 2>/dev/null
assert_eq "[DSRACE-4] zbuild_claim_release did NOT call the release hook (no claim held)" "" \
    "$(cat "$CALLS")" # [DSRACE-4]

cleanup_test_env
print_test_results
exit $((FAIL > 0))
