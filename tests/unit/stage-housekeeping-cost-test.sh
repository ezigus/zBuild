#!/usr/bin/env bash
# tests/unit/stage-housekeeping-cost-test.sh — per-dispatch housekeeping the
# shell can do itself (ADR-065 §5, round 6, C2). Each ran once per dispatch,
# ~57 times in one three-run pipeline test.
#
# K1 [change] sourcing scripts/lib/stage-result.sh starts no dirname
# K2 [change] stage_dispatch_mark starts nothing once its dir exists
# K3 [change] zbuild_goal_hash starts shasum only; zbuild_goal_key adds nothing
# K4 [guard]  …and both give the old pipelines' answers
# K5 [change] template_stage_roles starts nothing, and lists the roles as tr did
# K6 [change] _stage_block_rules starts no cat
# K7 [change] _router_clear_throttle_marker starts nothing when no marker is set
# K8 [change] _stage_io_now_short and _runner_now_short start no date, and
#             print date -u's answer
# K9 [change] persona_find_dir starts no dirname
# K10 [guard] zb_dirname_v gives dirname's answer for every shape of path
# K11 [change] a stage dispatch (plugin_hook_call run) starts no dirname, and
#             no mkdir or rm for its time-limit files once runtime/ exists
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "per-dispatch housekeeping: what it starts (ADR-065 §5)"
setup_test_env "stage-housekeeping-cost"

CALLS="$TEST_TEMP_DIR/calls"
_PROGS=(dirname basename mkdir rm cat tr cut sed date shasum awk)
_wrap()   { local c; for c in "${_PROGS[@]}"; do eval "$c() { printf '%s\\n' $c >> \"\$CALLS\"; command $c \"\$@\"; }"; done; }
_unwrap() { unset -f "${_PROGS[@]}"; }
_calls()  { command sort "$CALLS" | command tr '\n' ' ' | command sed 's/ $//'; }

print_test_section "K1: sourcing stage-result.sh"
: > "$CALLS"; _wrap
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
_unwrap
assert_eq "[K1] it starts no dirname" "" "$(grep -x dirname "$CALLS" | tr '\n' ' ')"
declare -F stage_result_write >/dev/null && assert_pass "[K1] …and it loaded" || assert_fail "[K1] …and it loaded" "stage_result_write missing"

print_test_section "K2: stage_dispatch_mark"
# shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
source "$REPO_ROOT/scripts/lib/stage-dispatch-mark.sh"
SD="$TEST_TEMP_DIR/state"; mkdir -p "$SD"; echo '{}' > "$SD/pipeline-state.json"
stage_dispatch_mark "$SD/pipeline-state.json" build
_mk="$(stage_dispatch_mark_path "$SD" build)"
: > "$CALLS"; _wrap
stage_dispatch_mark "$SD/pipeline-state.json" build
_unwrap
assert_eq "[K2] a second mark starts nothing" "" "$(_calls)"
assert_file_exists "[K2] …and the mark is there" "$_mk"

print_test_section "K3/K4: the goal hash and key"
# shellcheck source=../../scripts/lib/identity.sh
source "$REPO_ROOT/scripts/lib/identity.sh"
_g=$'  Fix the  thing\n\tnow  '
_old_hash="$(printf '%s' "$_g" | command tr -d '[:space:]' | command shasum -a 256 | command cut -d' ' -f1)"
: > "$CALLS"; _wrap
_h="$(zbuild_goal_hash "$_g")"
_unwrap
assert_eq "[K3] zbuild_goal_hash starts shasum only" "shasum" "$(_calls)"
assert_eq "[K4] …and gives the old hash" "$_old_hash" "$_h"
: > "$CALLS"; _wrap
_k="$(zbuild_goal_key "$_g")"
_unwrap
assert_eq "[K3] zbuild_goal_key starts shasum only" "shasum" "$(_calls)"
assert_eq "[K4] …and gives the old key" "goal-${_old_hash:0:12}" "$_k"
assert_eq "[K4] an empty hash input still hashes the empty string" \
    "$(printf '' | command shasum -a 256 | command cut -d' ' -f1)" "$(zbuild_goal_hash '')"

print_test_section "K5: template_stage_roles"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGE_ROLES_build="builder,fixer"
: > "$CALLS"; _wrap
_r="$(template_stage_roles build)"
_unwrap
assert_eq "[K5] it starts nothing" "" "$(_calls)"
assert_eq "[K5] …and lists each role on its own line" "$(command tr ',' '\n' <<< "builder,fixer")" "$_r"
_TPL_STAGE_ROLES_build="solo"
assert_eq "[K5] one role" "solo" "$(template_stage_roles build)"
unset _TPL_STAGE_ROLES_build

print_test_section "K6: _stage_block_rules"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
: > "$CALLS"; _wrap
_rules="$(_stage_block_rules build "$SD" "$TEST_TEMP_DIR/no-manifest.yaml" 2>/dev/null)"
_unwrap
assert_eq "[K6] it starts no cat" "" "$(grep -x cat "$CALLS" | tr '\n' ' ')"
assert_contains "[K6] …and still prints the rules" "$_rules" "### How every stage works"
assert_contains "[K6] …to their end" "$_rules" "$(sed -n '/^### How every stage works/,/^EOF/p' "$REPO_ROOT/scripts/lib/stage-prompt.sh" | sed '$d' | tail -1)"

print_test_section "K7: _router_clear_throttle_marker"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"
export ZBUILD_STATE_DIR="$SD"
: > "$CALLS"; _wrap
_router_clear_throttle_marker
_unwrap
assert_eq "[K7] with no marker it starts nothing" "" "$(_calls)"
unset ZBUILD_STATE_DIR

print_test_section "K8: the short clock"
# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=1792937616000
_want="$(command date -u -r 1792937616 +'%H:%M:%S UTC' 2>/dev/null || command date -u -d @1792937616 +'%H:%M:%S UTC')"
: > "$CALLS"; _wrap
_t="$(_stage_io_now_short)"
_unwrap
unset ZBUILD_STAGE_IO_NOW_MS_OVERRIDE
assert_eq "[K8] _stage_io_now_short starts no date" "" "$(_calls)"
assert_eq "[K8] …and prints date -u's answer" "$_want" "$_t"
_runner_now_ms() { printf '1792937616000'; }
eval "$(declare -f _runner_now_short 2>/dev/null || sed -n '/^_runner_now_short() {/,/^}/p' "$REPO_ROOT/core/pipeline/runner.sh")"
: > "$CALLS"; _wrap
_t2="$(_runner_now_short)"
_unwrap
assert_eq "[K8] _runner_now_short starts no date" "" "$(_calls)"
assert_eq "[K8] …and prints date -u's answer" "$_want" "$_t2"

print_test_section "K9: persona_find_dir"
# shellcheck source=../../scripts/lib/persona-resolve.sh
source "$REPO_ROOT/scripts/lib/persona-resolve.sh"
_pid="$(command ls "$REPO_ROOT/plugins/persona" | head -1)"
: > "$CALLS"; _wrap
_pd="$(ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" persona_find_dir "$_pid" 2>/dev/null)"
_unwrap
assert_eq "[K9] it starts no dirname" "" "$(grep -x dirname "$CALLS" | tr '\n' ' ')"
assert_eq "[K9] …and names the persona's dir" "$REPO_ROOT/plugins/persona/$_pid" "$_pd"

print_test_section "K10: zb_dirname_v == dirname"
_dm=0; _dd=""
for _p in /a/b/c /a/b/c/ /a//b //a / // a a/ a/b ./a ../a /a/b// "a b/c d" /.. . ..; do
    _w="$(command dirname -- "$_p")"; _g=""; zb_dirname_v _g "$_p"
    [[ "$_w" == "$_g" ]] || { _dm=$((_dm + 1)); _dd+="[$_p] dirname=[$_w] got=[$_g]; "; }
done
assert_eq "[K10] every path agrees" "0" "$_dm" "$_dd"

print_test_section "K11: a stage dispatch"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$SD"; mkdir -p "$SD/runtime"
mock_plugin_factory "hk" tool 0 >/dev/null
_HKD="$TEST_TEMP_DIR/plugins/tool/hk"
ZBUILD_CURRENT_STAGE=hk plugin_hook_call "$_HKD" run hk "$SD/pipeline-state.json" >/dev/null 2>&1 || true
# mkdir logs its arguments: the stub's own mkdir of artifacts/ is the stage's,
# not the engine's.
MKARGS="$TEST_TEMP_DIR/mkargs"; : > "$MKARGS"
: > "$CALLS"; _wrap
mkdir() { printf '%s\n' "$*" >> "$MKARGS"; command mkdir "$@"; }
ZBUILD_CURRENT_STAGE=hk plugin_hook_call "$_HKD" run hk "$SD/pipeline-state.json" >/dev/null 2>&1 || true
_unwrap
assert_eq "[K11] it starts no dirname" "" "$(grep -x dirname "$CALLS" | tr '\n' ' ')"
assert_eq "[K11] …and no mkdir of runtime/, which is there" "" "$(grep -F "$SD/runtime" "$MKARGS" | tr '\n' ' ')"
unset ZBUILD_STATE_DIR

cleanup_test_env
print_test_results
exit $((FAIL > 0))
