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
#   RQ3 [change] simple.yaml and deployed.yaml give pr `requires: all`: every
#                stage and loop the flow runs before it, not only the lenses'
#   RQ7 [change] (review) a unit a later one requires that did not pass ends the
#                run at once, naming the later unit — not after every stage
#                between has run
#   RQ8 [change] (review) a requires: that cannot be read refuses the template:
#                a bad name, the block-list form, one on a loop member
#   RQ9 [change] a unit another process recorded is read from the state file
#                (the memory of this shell's writes holds only its own)
#   RQ6 [change] `requires: all` means every earlier top-level unit; a stage
#                that failed without ending the run is not met
#   RQ10 [change] (#2614, ADR-068 §3) a stage marked as not blocking
#                (`blocking: false`, as hydrate is) is not part of `requires:
#                all`: its failure never holds back a later stage
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
# #2614: hydrate is not blocking, so it is not required; simple checks the
# issue (issue-check) before the loop.
for _t in "simple:intake issue-check delivery_loop" "deployed:intake delivery_loop"; do
    rc=0; load_template "$REPO_ROOT/config/templates/${_t%%:*}.yaml" >/dev/null 2>&1 || rc=$?
    assert_eq "[RQ3] ${_t%%:*}.yaml loads" "0" "$rc"
    assert_eq "[RQ3] ${_t%%:*}.yaml: pr requires every blocking stage before it" "${_t#*:}" "$(template_stage_requires pr)"
done

print_test_section "RQ6: requires: all"
T6="$TEST_TEMP_DIR/rq6.yaml"; _tpl "$T6" "  requires: all"
rc=0; load_template "$T6" >/dev/null 2>&1 || rc=$?
assert_eq "[RQ6] the template loads" "0" "$rc"
assert_eq "[RQ6] all = every unit the flow runs before it" "intake build" "$(template_stage_requires pr)"
SF6="$TEST_TEMP_DIR/state6.json"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}}' > "$SF6"
for _s in intake build; do _update_stage_status "$SF6" "$_s" complete >/dev/null 2>&1; done
_zbuild_state_set_stage_verdict "$SF6" intake pass >/dev/null 2>&1
_zbuild_state_set_stage_verdict "$SF6" build fail >/dev/null 2>&1
rc=0; stage_requires_gate "$SF6" pr || rc=$?
assert_eq "[RQ6] a stage that failed and did not end the run → not met" "build" "${_STAGE_REQUIRES_UNMET:-}"

print_test_section "RQ10: a stage that is not blocking is not required by all (#2614)"
T10="$TEST_TEMP_DIR/rq10.yaml"; _tpl "$T10" "  requires: all"
printf '%s\n' '  blocking: false' > "$T10.add"
awk -v f="$T10.add" '{print} /^intake:/ {while ((getline l < f) > 0) print l}' "$T10" > "$T10.new" && mv "$T10.new" "$T10"
rc=0; load_template "$T10" >/dev/null 2>&1 || rc=$?
assert_eq "[RQ10] the template loads" "0" "$rc"
assert_eq "[RQ10] all leaves out the stage that is not blocking" "build" "$(template_stage_requires pr)"
SF10="$TEST_TEMP_DIR/state10.json"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}}' > "$SF10"
for _s in intake build; do _update_stage_status "$SF10" "$_s" complete >/dev/null 2>&1; done
_zbuild_state_set_stage_verdict "$SF10" intake fail >/dev/null 2>&1
_zbuild_state_set_stage_verdict "$SF10" build pass >/dev/null 2>&1
rc=0; stage_requires_gate "$SF10" pr || rc=$?
assert_eq "[RQ10] it failed, and the later stage still runs" "0" "$rc"
T10b="$TEST_TEMP_DIR/rq10b.yaml"; _tpl "$T10b" "  requires: [intake, build]"
awk -v f="$T10.add" '{print} /^intake:/ {while ((getline l < f) > 0) print l}' "$T10b" > "$T10b.new" && mv "$T10b.new" "$T10b"
load_template "$T10b" >/dev/null 2>&1
assert_eq "[RQ10] a stage named by hand is still required" "intake build" "$(template_stage_requires pr)"

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

print_test_section "RQ7: a required unit that did not pass ends the run at once"
load_template "$T6" >/dev/null 2>&1
SF7="$TEST_TEMP_DIR/state7.json"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}}' > "$SF7"
_update_stage_status "$SF7" intake complete >/dev/null 2>&1
_zbuild_state_set_stage_verdict "$SF7" intake fail >/dev/null 2>&1
rc=0; stage_requires_ahead "$SF7" 1 || rc=$?
assert_eq "[RQ7] before build: intake failed, and pr requires it → stop now" "1" "$rc"
assert_eq "[RQ7] ...naming the unit that requires it" "pr" "${_STAGE_REQUIRES_HELD:-}"
assert_eq "[RQ7] ...and what it requires" "intake" "${_STAGE_REQUIRES_UNMET:-}"
_zbuild_state_set_stage_verdict "$SF7" intake pass >/dev/null 2>&1
rc=0; stage_requires_ahead "$SF7" 1 || rc=$?
assert_eq "[RQ7] intake passed → go on" "0" "$rc"
rc=0; stage_requires_ahead "$SF7" 0 || rc=$?
assert_eq "[RQ7] nothing has run yet → go on" "0" "$rc"

print_test_section "RQ9: a unit another process recorded is read from the file"
load_template "$T6" >/dev/null 2>&1
SF9="$TEST_TEMP_DIR/state9.json"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}}' > "$SF9"
( _update_stage_status "$SF9" intake complete; _zbuild_state_set_stage_verdict "$SF9" intake pass
  _update_stage_status "$SF9" build complete; _zbuild_state_set_stage_verdict "$SF9" build fail ) >/dev/null 2>&1
rc=0; stage_requires_gate "$SF9" pr || rc=$?
assert_eq "[RQ9] written elsewhere: build failed → not met" "build" "${_STAGE_REQUIRES_UNMET:-}"
( _zbuild_state_set_stage_verdict "$SF9" build pass ) >/dev/null 2>&1
rc=0; stage_requires_gate "$SF9" pr || rc=$?
assert_eq "[RQ9] ...and passed → met" "0" "$rc"

print_test_section "RQ8: a requires: that cannot be read refuses the template"
for _bad in "  requires: [deliv.ery]" "  requires:
    - intake"; do
    T8="$TEST_TEMP_DIR/rq8.yaml"; _tpl "$T8" "$_bad"
    rc=0; out="$(load_template "$T8" 2>&1)" || rc=$?
    assert_eq "[RQ8] refused: ${_bad//$'\n'/ }" "1" "$(( rc != 0 ))"
done
T8b="$TEST_TEMP_DIR/rq8b.yaml"
cat > "$T8b" <<'YAML'
id: rq
name: Requires
defaults:
  strategy: fanout
flow:
  - intake
  - loop
loop:
  type: cycle
  flow:
    - build
  exit_when:
    all:
      - { stage: build, field: verdict, op: eq, value: pass }
  max_iterations: 1
  on_max: halt
intake:
  roles: [intake]
build:
  roles: [builder]
  requires: [intake]
YAML
rc=0; out="$(load_template "$T8b" 2>&1)" || rc=$?
assert_eq "[RQ8] refused: requires: on a loop member" "1" "$(( rc != 0 ))"
assert_contains "[RQ8] ...and says so" "$out" "requires: is for a top-level stage"

print_test_section "RQ5: the runner asks the gate before each top-level unit"
_loop="$(awk '/for \(\( _ui = 0; _ui < \$\{#_TPL_DISPATCH_UNITS\[@\]\}/{p=1} p{print} p&&/case "\$_unit" in/{exit}' "$REPO_ROOT/core/pipeline/runner.sh")"
assert_contains "[RQ5] the gate is asked before the unit's case" "$_loop" "stage_requires_gate"
assert_contains "[RQ5] ...a later unit's requires are asked too" "$_loop" "stage_requires_ahead"
_lin="$(awk '/for stage in "\$\{active_stages\[@\]\}"; do/{n++} n==2{print} n==2&&/When resuming, skip stages/{exit}' "$REPO_ROOT/core/pipeline/runner.sh")"
assert_contains "[RQ5] the linear loop asks the gate too" "$_lin" "stage_requires_gate"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
