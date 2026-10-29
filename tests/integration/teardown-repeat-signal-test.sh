#!/usr/bin/env bash
# Integration: a second signal during teardown does not cut it short
# (ADR-054 §7, §11).
#
# Why: `timeout` sends its TERM twice — to the run, then to the run's whole
# process group — and an operator presses Ctrl-C twice. The first signal starts
# the EXIT trap; the always-run stages (release, persist) then run inside it.
# The trap put the run's own TERM handler back before dispatching them, so a
# second TERM arriving there ran that handler, whose `exit 1` ended the trap:
# the stages after it never ran. On ubuntu CI (2026-10-29, #2424 and #2423)
# runner-release-exit-paths SPEC-5 lost every release this way.
#
# T1 a TERM that arrives while release runs: release still finishes
# T2 ...and persist, the always-run stage after it, still runs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a second signal during teardown does not cut it short (ADR-054 §7)"
setup_test_env "teardown-repeat-signal"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0 ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

REPO="$(setup_git_temp_repo teardown-repeat-signal)"
mkdir -p "$REPO/.zbuild/templates"
cat > "$REPO/.zbuild/templates/teardown-two.yaml" <<'EOF'
id: teardown-two
extends: simple
flow:
  - outcome
always_run:
  - release
  - persist
outcome:
  gate: auto
release:
  gate: auto
  roles: [teardown]
  timeout_s: 30
persist:
  gate: auto
  roles: [persist]
  timeout_s: 30
EOF
(cd "$REPO" && git add .zbuild && git commit -qm "teardown-two template") >/dev/null 2>&1

STARTED="$TEST_TEMP_DIR/outcome-started"
REL_IN="$TEST_TEMP_DIR/release-entered"; REL_OUT="$TEST_TEMP_DIR/release-finished"
PERSISTED="$TEST_TEMP_DIR/persist-ran"
mock_plugin_factory outcome agent 0 "" "" >/dev/null
mock_plugin_factory teardown tool 0 "" teardown >/dev/null
mock_plugin_factory persister tool 0 "" persist >/dev/null
cat > "$PLUGINS_ROOT/agent/outcome/plugin.sh" <<PLUG
outcome_run() { : > "$STARTED"; sleep 60; return 0; }
PLUG
# Release takes 3 s: long enough for the second TERM to land inside it.
cat > "$PLUGINS_ROOT/tool/teardown/plugin.sh" <<PLUG
teardown_run() { : > "$REL_IN"; sleep 3; : > "$REL_OUT"; return 0; }
PLUG
cat > "$PLUGINS_ROOT/tool/persister/plugin.sh" <<PLUG
persister_run() { : > "$PERSISTED"; return 0; }
PLUG

( cd "$REPO" && exec bash "$RUNNER" --template teardown-two --goal "teardown repeat signal" ) \
    > "$TEST_TEMP_DIR/run.out" 2>&1 &
RUNNER_PID=$!
for _ in $(seq 1 300); do [[ -e "$STARTED" ]] && break; sleep 0.1; done
kill -TERM "$RUNNER_PID" 2>/dev/null || true
for _ in $(seq 1 300); do [[ -e "$REL_IN" ]] && break; sleep 0.1; done
# The repeat: to the run itself, as `timeout` and a second Ctrl-C do.
kill -TERM "$RUNNER_PID" 2>/dev/null || true
for _ in $(seq 1 600); do kill -0 "$RUNNER_PID" 2>/dev/null || break; sleep 0.1; done
kill -KILL "$RUNNER_PID" 2>/dev/null || true
wait "$RUNNER_PID" 2>/dev/null || true

if [[ ! -e "$REL_IN" ]]; then
    assert_fail "[setup] release started" "$(tail -20 "$TEST_TEMP_DIR/run.out")"
fi
assert_file_exists "[T1] release finishes despite a second TERM" "$REL_OUT"
assert_file_exists "[T2] persist still runs after it" "$PERSISTED"

print_test_results
exit $((FAIL > 0))
