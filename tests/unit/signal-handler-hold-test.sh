#!/usr/bin/env bash
# Unit: a signal handler is not run again by a repeat signal while it runs
# (ADR-054 §7, #2493).
#
# `timeout` sends its TERM twice, and a stage's or the run's watchdog TERMs the
# whole group, so a second TERM landing inside a TERM handler is normal. Bash
# then runs the handler again inside itself. On Ubuntu's bash (5.2.21) that
# inner run broke the outer one off when the outer was part-way through a
# command substitution ("unexpected EOF while looking for matching `)'"), and
# the run went on as if never signalled. Each handler therefore ignores INT and
# TERM first. Here each one's first step sends its own shell a TERM.
#
# H1 the cycle's handler runs once
# H2 the parallel group's handler runs once
# H3 the model loop's handler runs once
# H4 a stage's signal guard runs its callback once
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "a signal handler is not run again by a repeat signal (ADR-054 §7)"
setup_test_env "signal-handler-hold"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
export REPO_ROOT ENTRIES="$TEST_TEMP_DIR/entries"

# _entries <script> — run <script> in its own bash; it installs a handler and
# TERMs itself. Echo how many times the handler's first step ran.
_entries() {
    : > "$ENTRIES"
    timeout 20 bash -c "$1" >/dev/null 2>&1 || true
    grep -c x "$ENTRIES"
}
# The handler's first step: note it, and send the shell a second TERM.
_REPEAT='_zbuild_arm_abort_sentinel() { echo x >> "$ENTRIES"; kill -TERM "$BASHPID"; sleep 0.2; }'

print_test_section "H1: the cycle's handler"
assert_eq "[H1] the cycle's handler runs once" "1" "$(_entries '
    source "$REPO_ROOT/core/event-bus/event-bus.sh"
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
    '"$_REPEAT"'
    _cycle_install_traps; kill -TERM "$BASHPID"; sleep 0.5')"

print_test_section "H2: the parallel group's handler"
assert_eq "[H2] the parallel group's handler runs once" "1" "$(_entries '
    source "$REPO_ROOT/core/event-bus/event-bus.sh"
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
    '"$_REPEAT"'
    _parallel_install_traps; kill -TERM "$BASHPID"; sleep 0.5')"

print_test_section "H3: the model loop's handler"
assert_eq "[H3] the model loop's handler runs once" "1" "$(_entries '
    source "$REPO_ROOT/core/router/route.sh"
    eb_emit_event() { echo x >> "$ENTRIES"; kill -TERM "$BASHPID"; sleep 0.2; }
    _route_loop_install_traps; kill -TERM "$BASHPID"; sleep 0.5')"

print_test_section "H4: a stage's signal guard"
assert_eq "[H4] a stage's signal guard runs its callback once" "1" "$(_entries '
    source "$REPO_ROOT/scripts/lib/stage-signal.sh"
    _cb() { echo x >> "$ENTRIES"; kill -TERM "$BASHPID"; sleep 0.2; }
    stage_signal_begin _cb; kill -TERM "$BASHPID"; sleep 0.5')"

print_test_results
exit $((FAIL > 0))
