#!/usr/bin/env bash
# tests/unit/stage-requires-test.sh — a stage runs only when the stages it
# requires passed (#2611 R4, ADR-068 §3): the template says so, the engine
# checks it, and no lens-only flag stands in for it.
#
# On #2533 run 45644128060 the only thing between a failed review and a PR was
# ZBUILD_RUN_FLAGGED, a word only a map group set.
#
#   RQ1 [change] a top-level stage's `requires: [<stage>, …]` loads
#   RQ2 [change] a name that is not an earlier stage in the flow refuses the
#                template
#   RQ3 [change] simple.yaml and deployed.yaml give pr requires: [delivery_loop]
#   RQ4 [change] the gate: every required stage complete with a pass → met,
#                and the stage is told (ZBUILD_STAGE_REQUIRES_MET=yes); one not
#                → the run ends, failed, naming it; no requires: → nothing to
#                meet, and the stage is not told it was met
#   RQ5 [change] the runner asks the gate before each top-level unit
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a stage requires earlier stages to have passed (#2611)"
setup_test_env "stage-requires"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../scripts/lib/stage-requires.sh
source "$REPO_ROOT/scripts/lib/stage-requires.sh"

_tpl() {   # _tpl <file> <requires line for pr>
    cat > "$1" <<EOF
id: rq
name: Requires
defaults:
  strategy: fanout
flow:
  - intake
  - build
  - pr
intake:
  roles: [intake]
build:
  roles: [builder]
pr:
  roles: [pr]
$2
EOF
}

print_test_section "RQ1: requires: loads"
T1="$TEST_TEMP_DIR/rq1.yaml"; _tpl "$T1" "  requires: [intake, build]"
rc=0; load_template "$T1" >/dev/null 2>&1 || rc=$?
assert_eq "[RQ1] the template loads" "0" "$rc"
assert_eq "[RQ1] pr requires intake and build" "intake build" "$(template_stage_requires pr)"
assert_eq "[RQ1] a stage with none requires nothing" "" "$(template_stage_requires build)"

print_test_section "RQ2: a name that is not an earlier stage refuses the template"
T2="$TEST_TEMP_DIR/rq2.yaml"; _tpl "$T2" "  requires: [deploy]"
rc=0; out="$(load_template "$T2" 2>&1)" || rc=$?
assert_eq "[RQ2] not in the flow → refused" "1" "$(( rc != 0 ))"
assert_contains "[RQ2] ...and says which" "$out" "requires 'deploy'"
T3="$TEST_TEMP_DIR/rq3.yaml"
cat > "$T3" <<'EOF'
id: rq
name: Requires
defaults:
  strategy: fanout
flow:
  - intake
  - pr
  - build
intake:
  roles: [intake]
build:
  roles: [builder]
  requires: [intake]
pr:
  roles: [pr]
  requires: [build]
EOF
rc=0; out="$(load_template "$T3" 2>&1)" || rc=$?
assert_eq "[RQ2] a later stage → refused" "1" "$(( rc != 0 ))"
assert_contains "[RQ2] ...and says which" "$out" "requires 'build'"

print_test_section "RQ3: the shipped templates"
for _t in simple deployed; do
    rc=0; load_template "$REPO_ROOT/config/templates/$_t.yaml" >/dev/null 2>&1 || rc=$?
    assert_eq "[RQ3] $_t.yaml loads" "0" "$rc"
    assert_eq "[RQ3] $_t.yaml: pr requires delivery_loop" "delivery_loop" "$(template_stage_requires pr)"
done

print_test_section "RQ4: the gate"
load_template "$T1" >/dev/null 2>&1
SF="$TEST_TEMP_DIR/state.json"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}}' > "$SF"
_update_stage_status "$SF" intake complete >/dev/null 2>&1
_zbuild_state_set_stage_verdict "$SF" intake pass >/dev/null 2>&1
_update_stage_status "$SF" build complete >/dev/null 2>&1
_zbuild_state_set_stage_verdict "$SF" build pass >/dev/null 2>&1
unset ZBUILD_STAGE_REQUIRES_MET
rc=0; stage_requires_gate "$SF" pr || rc=$?
assert_eq "[RQ4] both passed → met" "0" "$rc"
assert_eq "[RQ4] ...and the stage is told" "yes" "${ZBUILD_STAGE_REQUIRES_MET:-unset}"
_zbuild_state_set_stage_verdict "$SF" build fail >/dev/null 2>&1
rc=0; stage_requires_gate "$SF" pr || rc=$?
assert_eq "[RQ4] build failed → not met" "1" "$rc"
assert_eq "[RQ4] ...the unmet names it" "build" "${_STAGE_REQUIRES_UNMET:-}"
assert_eq "[RQ4] ...and the stage is not told it was met" "unset" "${ZBUILD_STAGE_REQUIRES_MET:-unset}"
_zbuild_state_set_stage_verdict "$SF" build pass >/dev/null 2>&1
_update_stage_status "$SF" intake failed >/dev/null 2>&1
rc=0; stage_requires_gate "$SF" pr || rc=$?
assert_eq "[RQ4] intake not complete → not met" "intake" "${_STAGE_REQUIRES_UNMET:-}"
export ZBUILD_STAGE_REQUIRES_MET=yes
rc=0; stage_requires_gate "$SF" build || rc=$?
assert_eq "[RQ4] no requires: → nothing to meet" "0" "$rc"
assert_eq "[RQ4] ...and the stage is not told it was met" "unset" "${ZBUILD_STAGE_REQUIRES_MET:-unset}"

print_test_section "RQ5: the runner asks the gate before each top-level unit"
_loop="$(awk '/for \(\( _ui = 0; _ui < \$\{#_TPL_DISPATCH_UNITS\[@\]\}/{p=1} p{print} p&&/case "\$_unit" in/{exit}' "$REPO_ROOT/core/pipeline/runner.sh")"
assert_contains "[RQ5] the gate is asked before the unit's case" "$_loop" "stage_requires_gate"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
