#!/usr/bin/env bash
# Integration test (#1805, ADR-021 amended 2026-11-13): `--resume --from-stage <s>`
# may name a stage inside a cycle, inside a nested cycle, a nested cycle itself,
# or a stage after a cycle. Every cycle the run enters starts fresh at round 1;
# in that first round the members before <s> are not dispatched.
#
#   FSIC-1  --from-stage test     (inside inner_cycle inside outer_cycle)
#   FSIC-2  --from-stage probe    (inside outer_cycle, after inner_cycle)
#   FSIC-3  --from-stage inner_cycle (a nested cycle)
#   FSIC-4  --from-stage verify   (after the cycle)
#   FSIC-5  --from-stage outer_cycle (a cycle whose first member is a cycle)
#
# Fixture: tests/fixtures/templates/from-stage-in-cycle.yaml —
#   intake, outer_cycle { inner_cycle { build, test }, probe }, verify.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "--from-stage inside and after a cycle (#1805)"
setup_test_env "from-stage-in-cycle-1805"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo from-stage-in-cycle)"
_FIXTURE_TPL="$REPO_ROOT/tests/fixtures/templates/from-stage-in-cycle.yaml"
DISPATCH_LOG="$TEST_TEMP_DIR/dispatched.log"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_VISION_GATE=off
export ZBUILD_DISPATCH_LOG="$DISPATCH_LOG"

# Each stub logs that it ran and writes a passing result with the engine's writer.
_make_plugin() {
    local id="$1" role="$2"
    local dir="$PLUGINS_ROOT/agent/$id" fn="${1//-/_}_run"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
provides:
  role: $role
  result_contract: 3
hooks:
  run: $fn
requires:
  core:
    - redaction
outputs:
  - id: ${id}_result
    path: \${artifact_dir}/${id}-result.json
    type: json
    required: true
    primary: true
    finding_topics: none
EOF
    cat > "$dir/plugin.sh" <<PLUGIN
${fn}() {
    printf '%s\n' "$id" >> "\${ZBUILD_DISPATCH_LOG:-/dev/null}"
    local state_dir; state_dir="\$(dirname "\$2")"
    mkdir -p "\$state_dir/artifacts"
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\$state_dir/artifacts/${id}-result.json" pass "stub"
    return 0
}
PLUGIN
}
while read -r s r; do _make_plugin "$s" "$r"; done <<'STUBS'
intake intake
build builder
test tester
probe reviewer
verify verifier
STUBS

# _run_from <case> <stage> — an interrupted run in which every stage completed
# but verify, and both cycles had reached round 2, resumed with --from-stage
# <stage>. verify, never run, has no output.
# Sets _RF_RC, _RF_ERR (stderr+stdout) and _RF_EVENTS (the events file).
_run_from() {
    local case_id="$1" target="$2" sd="$TEST_TEMP_DIR/$1-state" s
    mkdir -p "$sd/artifacts" "$TEST_TEMP_DIR/$1-events"
    for s in intake build test probe; do
        printf '{"result_contract":3,"outcome":"pass","reason":"prior"}' > "$sd/artifacts/$s-result.json"
    done
    jq -n --argjson issue "$_ZB_ISSUE" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
        schema_version: 1, run_id: "fsic-1805", issue: $issue, status: "in_progress",
        stage_statuses: {intake:"complete", build:"complete", test:"complete",
                         probe:"complete", verify:"pending"},
        stage_verdicts: {intake:"pass", build:"pass", test:"pass", probe:"pass"},
        current_iteration: 0, self_heal_count: {}, scope_manifest_hash: "",
        cost_ledger_pointer: 0, claim_lease_id: "", plugin_state: {}, updated_at: $now
    }' > "$sd/pipeline-state.json"
    # Both cycles were in round 2 when the run stopped (the engine's own writer).
    zb_engine_loop_state "$sd/pipeline-state.json" outer_cycle 2 3 in_progress
    zb_engine_loop_state "$sd/pipeline-state.json" inner_cycle 2 3 in_progress
    : > "$DISPATCH_LOG"
    _RF_EVENTS="$TEST_TEMP_DIR/$case_id-events/events.jsonl"
    _RF_RC=0
    (
        cd "$_ZB_REPO" || exit 1
        export ZBUILD_STATE_DIR="$sd" ZBUILD_STATE_FILE="$sd/pipeline-state.json"
        export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/$case_id-events" ZBUILD_EVENTS_JSONL="$_RF_EVENTS"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
        resolve_template_file() { echo "$_FIXTURE_TPL"; }
        main --issue "$_ZB_ISSUE" --template from-stage-in-cycle --resume --from-stage "$target"
    ) >"$TEST_TEMP_DIR/$case_id.out" 2>&1 || _RF_RC=$?
    _RF_ERR="$(cat "$TEST_TEMP_DIR/$case_id.out")"
    _RF_RAN="$(tr '\n' ' ' < "$DISPATCH_LOG")"; _RF_RAN="${_RF_RAN% }"
}

# _refused <text> — "yes" when the run was refused for landing inside or after a cycle.
_refused() { [[ "$1" == *"inside or after a cycle"* ]] && echo yes || echo no; }

# _cycle_start_iters <events> <cycle> — the iter of every cycle.start for <cycle>.
_cycle_start_iters() {
    [[ -f "$1" ]] || return 0
    jq -r --arg c "$2" 'select(.type=="cycle.start" and .data.cycle_id==$c) | .data.iter' "$1" | tr '\n' ' '
}

print_test_section "FSIC-1: --from-stage test (inside a nested cycle) starts there, every cycle at round 1"
_run_from fsic1 test
assert_eq "FSIC-1: not refused as inside a cycle" "no" "$(_refused "$_RF_ERR")"
assert_eq "FSIC-1: test, then probe, then verify run; intake and build do not" "test probe verify" "$_RF_RAN"
assert_eq "FSIC-1: outer_cycle starts at round 1, not the interrupted round 2" "1 " "$(_cycle_start_iters "$_RF_EVENTS" outer_cycle)"
assert_eq "FSIC-1: inner_cycle starts at round 1, not the interrupted round 2" "1 " "$(_cycle_start_iters "$_RF_EVENTS" inner_cycle)"
_fsic1_ss="$(jq -rn 'first(inputs | select(.type=="stage.start") | .data.stage)' "$_RF_EVENTS" 2>/dev/null || true)"
assert_eq "FSIC-1: the first stage.start is the target's" "test" "$_fsic1_ss"
assert_eq "FSIC-1: the run ends 0" "0" "$_RF_RC"

print_test_section "FSIC-2: --from-stage probe (after a nested cycle, inside the outer one)"
_run_from fsic2 probe
assert_eq "FSIC-2: not refused" "no" "$(_refused "$_RF_ERR")"
assert_eq "FSIC-2: probe, then verify run; the inner cycle does not" "probe verify" "$_RF_RAN"
assert_eq "FSIC-2: outer_cycle starts at round 1" "1 " "$(_cycle_start_iters "$_RF_EVENTS" outer_cycle)"

print_test_section "FSIC-3: --from-stage inner_cycle (a nested cycle) runs it from its first member"
_run_from fsic3 inner_cycle
assert_eq "FSIC-3: not refused" "no" "$(_refused "$_RF_ERR")"
assert_eq "FSIC-3: build, test, probe, verify run; intake does not" "build test probe verify" "$_RF_RAN"
assert_eq "FSIC-3: inner_cycle starts at round 1" "1 " "$(_cycle_start_iters "$_RF_EVENTS" inner_cycle)"

print_test_section "FSIC-4: --from-stage verify (after the cycle) runs only verify"
_run_from fsic4 verify
assert_eq "FSIC-4: not refused as after a cycle" "no" "$(_refused "$_RF_ERR")"
assert_eq "FSIC-4: only verify runs" "verify" "$_RF_RAN"
assert_eq "FSIC-4: the run ends 0" "0" "$_RF_RC"

print_test_section "FSIC-5: --from-stage outer_cycle (first member a cycle) checks only the stages before it"
_run_from fsic5 outer_cycle
assert_eq "FSIC-5: not refused for a missing output of a stage after the target" "no" \
    "$([[ "$_RF_ERR" == *"has no restorable primary artifact"* ]] && echo yes || echo no)"
assert_eq "FSIC-5: build, test, probe, verify run; intake does not" "build test probe verify" "$_RF_RAN"
assert_eq "FSIC-5: the run ends 0" "0" "$_RF_RC"

print_test_results
cleanup_test_env
