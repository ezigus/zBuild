#!/usr/bin/env bash
# tests/unit/hooks-no-event-leak-test.sh — the repository's Claude Code hooks
# record an event only where a zbuild run keeps them (#2541, ADR-035).
#
# Why: `.claude/helpers/hook-handler.cjs` emits an event on every tool call. With
# no events path in its environment, the event bus made a folder per process
# under ~/.zbuild/ephemeral-events, and the hook process lives milliseconds:
# 56,505 folders (1.7 GB) on one machine, none ever read or removed.
#
# H1 [change] a hook run with no events path in its environment leaves no
#             folder under <home>/.zbuild/ephemeral-events
# H2 [change] ...nor under a data root it is given
# H3 [done]   a hook run inside a zbuild run (ZBUILD_EVENTS_JSONL set) records
#             its event there
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "hooks record events only where a run keeps them (#2541)"
setup_test_env "hooks-no-event-leak"

HOOK="$REPO_ROOT/.claude/helpers/hook-handler.cjs"
H="$TEST_TEMP_DIR/home"; mkdir -p "$H"
_hook() {   # <subcommand> <payload> [VAR=value ...] — the hook in a clean environment
    local sub="$1" payload="$2"; shift 2
    env -i PATH="$PATH" HOME="$H" "$@" node "$HOOK" "$sub" <<< "$payload" >/dev/null 2>&1
    return 0
}
_count() { find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

_hook post-bash '{"tool_input":{"command":"ls"},"tool_response":{"exitCode":0}}'
_hook pre-bash '{"tool_input":{"command":"ls"}}'
_hook route '{"prompt":"hello"}'
assert_eq "[H1] no folder under the home's ephemeral-events after three hooks" "0" "$(_count "$H/.zbuild/ephemeral-events")"

D="$TEST_TEMP_DIR/data"; mkdir -p "$D"
_hook post-bash '{"tool_input":{"command":"ls"},"tool_response":{"exitCode":0}}' ZBUILD_DATA_ROOT="$D"
assert_eq "[H2] no folder under a data root it is given" "0" "$(_count "$D/ephemeral-events")"

RUN="$TEST_TEMP_DIR/run"; mkdir -p "$RUN"
_hook post-bash '{"tool_input":{"command":"ls -la"},"tool_response":{"exitCode":0}}' \
    ZBUILD_EVENTS_JSONL="$RUN/events.jsonl" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
assert_eq "[H3] inside a run, the hook's event is in the run's log" "hook.post_bash" \
    "$(jq -r 'select(.type=="hook.post_bash") | .type' "$RUN/events.jsonl" 2>/dev/null | tail -1)"
assert_eq "[H3] ...and no folder under the home" "0" "$(_count "$H/.zbuild/ephemeral-events")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
