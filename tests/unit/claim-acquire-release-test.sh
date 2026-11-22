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
    "run_id=run-cl-1 machine=box-1" "$(_event pipeline.claim.acquired | jq -r .holder)"
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
