#!/usr/bin/env bash
# tests/unit/test-kill-tree-test.sh — a test that has to KILL a runner kills
# everything the runner started (zb_test_kill_tree, scripts/lib/test-helpers.sh).
#
# KILL cannot be caught, so a runner killed alone cleans up nothing: its forked
# stage and the stage's time-limit watchdog — copies of the runner's shell, so
# they show as runner.sh — were left running, the watchdog for up to the stage's
# limit (900s by default). A suite under load left one each time an abort test
# gave up waiting and went straight to KILL.
#
# K1 [change] a process and everything under it, three deep, are all gone
# K2 [change] a stage dispatch killed mid-stage leaves no stage, no plugin and
#             no watchdog behind
# K3 [guard]  a pid that is already gone is not an error
# K4 [change] …nor under set -e, where the abort tests run: their runner has
#             usually exited on its TERM by the time they reap it
# K5 [change] it stops nothing on the way: a stopped process whose parent dies
#             leaves an orphaned process group with a stopped member, and the
#             kernel then hangs up that whole group — on macOS CI the test's
#             own (it died 0.9s in, twice, with no assertion failing)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zb_test_kill_tree: a killed runner leaves nothing behind"
setup_test_env "test-kill-tree"

# tree_of <pid>: the pid and every process under it, listed independently of
# the helper under test.
tree_of() { local c; printf '%s\n' "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree_of "$c"; done; }
alive() { local p n=0; for p in $1; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; printf '%s' "$n"; }
# wait_tree <pid> <n>: until the tree has at least <n> processes (10s at most).
wait_tree() { local i; for (( i = 0; i < 100; i++ )); do (( $(tree_of "$1" | grep -c .) >= $2 )) && return 0; sleep 0.1; done; return 1; }

if ! declare -F zb_test_kill_tree >/dev/null; then
    assert_fail "[K0] zb_test_kill_tree exists" "not defined in test-helpers.sh"
    cleanup_test_env; print_test_results; exit 1
fi

print_test_section "K1: three deep"
bash -c '( ( sleep 300 ) & sleep 300 ) & sleep 300' &
_top=$!
wait_tree "$_top" 5
_all="$(tree_of "$_top")"
zb_test_kill_tree "$_top"
wait "$_top" 2>/dev/null
sleep 0.3
assert_eq "[K1] all $(grep -c . <<< "$_all") processes are gone" "0" "$(alive "$_all")"

print_test_section "K2: a dispatch killed mid-stage"
SD="$TEST_TEMP_DIR/state"; mkdir -p "$SD/runtime"; printf '{}\n' > "$SD/pipeline-state.json"
mock_plugin_factory "slow" tool 0 >/dev/null
PD="$TEST_TEMP_DIR/plugins/tool/slow"
printf 'slow_run() { sleep 300; }\n' > "$PD/plugin.sh"
sed -i.bak 's/^  run: .*/  run: slow_run/' "$PD/manifest.yaml" && rm -f "$PD/manifest.yaml.bak"
REPO_ROOT="$REPO_ROOT" SD="$SD" PD="$PD" TEST_TEMP_DIR="$TEST_TEMP_DIR" bash -c '
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    source "$REPO_ROOT/core/event-bus/event-bus.sh"
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
    export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
    export ZBUILD_STATE_DIR="$SD"
    ZBUILD_CURRENT_STAGE=slow plugin_hook_call "$PD" run slow "$SD/pipeline-state.json"' >"$TEST_TEMP_DIR/disp.log" 2>&1 &
_disp=$!
# The stage names itself in this file as its first act, after the watchdog is
# started; then the plugin's sleep follows. Five processes: the dispatch, the
# watchdog and its sleep, the stage and its plugin's sleep.
for (( _i = 0; _i < 100; _i++ )); do [[ -s "$SD/runtime/stage-time-limit.slow.pid" ]] && break; sleep 0.1; done
for (( _i = 0; _i < 50; _i++ )); do pgrep -P "$(cat "$SD/runtime/stage-time-limit.slow.pid" 2>/dev/null)" >/dev/null 2>&1 && break; sleep 0.1; done
_n="$(tree_of "$_disp" | grep -c .)"
[[ "$_n" -ge 5 ]] || assert_fail "[K2] setup: the stage and its watchdog started" "$_n processes; $(head -c 400 "$TEST_TEMP_DIR/disp.log")"
_all="$(tree_of "$_disp")"
zb_test_kill_tree "$_disp"
wait "$_disp" 2>/dev/null
sleep 0.3
assert_eq "[K2] all $(grep -c . <<< "$_all") processes are gone, the watchdog among them" "0" "$(alive "$_all")"

print_test_section "K3: already gone"
bash -c 'exit 0' & _gone=$!; wait "$_gone"
zb_test_kill_tree "$_gone"; _rc=$?
assert_eq "[K3] returns 0" "0" "$_rc"
_k4="$(REPO_ROOT="$REPO_ROOT" G="$_gone" bash -c 'set -euo pipefail
    source "$REPO_ROOT/scripts/lib/helpers.sh"; source "$REPO_ROOT/scripts/lib/test-helpers.sh"
    zb_test_kill_tree "$G"; echo carried-on' 2>/dev/null || true)"
assert_eq "[K4] under set -e the caller carries on" "carried-on" "$_k4"

print_test_section "K5: nothing is stopped"
SIGS="$TEST_TEMP_DIR/sigs"; : > "$SIGS"
kill() { [[ "${1:-}" == -* ]] && printf '%s\n' "$1" >> "$SIGS"; builtin kill "$@"; }
bash -c '( sleep 300 ) & sleep 300' &
_k5=$!
wait_tree "$_k5" 3
_all="$(tree_of "$_k5")"
zb_test_kill_tree "$_k5"
wait "$_k5" 2>/dev/null
unset -f kill
sleep 0.3
assert_eq "[K5] no STOP is sent" "" "$(grep -x -e -STOP -e -SIGSTOP -e -19 -e -17 "$SIGS" | tr '\n' ' ')"
assert_eq "[K5] …and the tree is still gone" "0" "$(alive "$_all")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
