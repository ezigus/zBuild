#!/usr/bin/env bash
# tests/unit/call-time-up-hook-test.sh — a model call is told its time is up a
# minute before it is cut off, and is left only its notes file to write
# (ADR-063, amended 2026-11-08, #2503).
#
# Why: on #1805 run 42523805245 eight calls were killed at their time limit.
# Build had found why a test failed ("the mock doesn't have role: intake") and
# was cut off before it wrote that down; none of the eight reported its cost,
# which Claude gives only in a call's last message.
#
# H1 [change] a call's settings file holds a PreToolUse hook naming the call's
#             deadline (its time limit less a minute) and the stage's notes file
# H2 [change] a call of a minute or less gets no hook
# H3 [change] before the deadline the hook allows every tool
# H4 [change] after it, the hook refuses a tool and says why: time is up, write
#             your notes, give your final reply
# H5 [change] ...but allows writing or editing the stage's notes file, and
#             nothing else
# H6 [change] with no notes file, every tool is refused after the deadline
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a call is told its time is up a minute before it is cut off (#2503)"
setup_test_env "call-time-up-hook"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/router/permissions.sh
source "$REPO_ROOT/core/router/permissions.sh"

export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch" ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" ZBUILD_CURRENT_STAGE=build
export ZBUILD_ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ZBUILD_STAGE_SCRATCH" "$ZBUILD_REPO_ROOT" "$ZBUILD_ARTIFACT_DIR"
NOTES="$(stage_notes_path "$ZBUILD_STATE_DIR" build)"
HOOK="$REPO_ROOT/core/router/time-up-hook.sh"

# ── H1 / H2 ──────────────────────────────────────────────────────────────────
print_test_section "H1/H2: the settings file holds the hook"
_now=$(date +%s)
_zbuild_build_permissions_settings 900 >/dev/null 2>&1
_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE")"
assert_contains "[H1] the hook is the router's time-up hook" "$_cmd" "core/router/time-up-hook.sh"
assert_contains "[H1] ...given the stage's notes file" "$_cmd" "$NOTES"
_dl="$(awk '{print $(NF-1)}' <<< "$_cmd")"
_off=$(( _dl - _now ))
assert_eq "[H1] ...and a deadline a minute before the call's limit" "1" "$(( _off >= 838 && _off <= 842 ? 1 : 0 ))"
assert_eq "[H1] it matches every tool" "*" "$(jq -r '.hooks.PreToolUse[0].matcher' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE")"
assert_eq "[H1] the deny rules are kept" "array" "$(jq -r '.permissions.deny | type' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE")"
_zbuild_build_permissions_settings 60 >/dev/null 2>&1
assert_eq "[H2] a call of a minute or less gets no hook" "null" "$(jq -c '.hooks' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE")"

# ── H3–H6 ────────────────────────────────────────────────────────────────────
_call() {   # <deadline> <notes> <tool> [file_path] — the hook's answer
    local in; in="$(jq -cn --arg t "$3" --arg f "${4:-}" '{tool_name:$t, tool_input:(if $f == "" then {command:"ls"} else {file_path:$f} end)}')"
    bash "$HOOK" "$1" "$2" <<< "$in"
}
_decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "${1:-{\}}" 2>/dev/null || echo allow; }

print_test_section "H3: before the deadline every tool is allowed"
_out="$(_call $(( _now + 600 )) "$NOTES" Bash)"
assert_eq "[H3] a tool before the deadline is allowed" "" "$_out"

print_test_section "H4: after it a tool is refused, and the model is told why"
_out="$(_call $(( _now - 1 )) "$NOTES" Bash)"
assert_eq "[H4] a tool after the deadline is refused" "deny" "$(_decision "$_out")"
_why="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$_out")"
assert_contains "[H4] ...told its time is up" "$_why" "Time is up"
assert_contains "[H4] ...to write its notes file" "$_why" "$NOTES"
assert_contains "[H4] ...and to give its final reply with its answers" "$_why" "give your final reply now, with your answer to every finding"

print_test_section "H5: only the notes file may still be written"
assert_eq "[H5] writing the notes file is allowed" "" "$(_call $(( _now - 1 )) "$NOTES" Write "$NOTES")"
assert_eq "[H5] editing it is allowed" "" "$(_call $(( _now - 1 )) "$NOTES" Edit "$NOTES")"
assert_eq "[H5] writing another file is refused" "deny" "$(_decision "$(_call $(( _now - 1 )) "$NOTES" Write "$TEST_TEMP_DIR/repo/x.sh")")"
assert_eq "[H5] reading the notes file is refused" "deny" "$(_decision "$(_call $(( _now - 1 )) "$NOTES" Read "$NOTES")")"

print_test_section "H6: with no notes file, every tool is refused"
assert_eq "[H6] a write is refused" "deny" "$(_decision "$(_call $(( _now - 1 )) "" Write "$NOTES")")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
