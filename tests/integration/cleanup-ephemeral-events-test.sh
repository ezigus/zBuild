#!/usr/bin/env bash
# tests/integration/cleanup-ephemeral-events-test.sh — `zbuild cleanup
# --tmpdirs` reclaims the event bus's stale per-process folders (#2541, ADR-035).
#
# Why: with no events path pinned, core/event-bus/event-bus.sh records into
# <data root>/ephemeral-events/<pid> (ADR-035: process-scoped, never global).
# Nothing removed them: 56,505 had piled up on one machine.
#
# E1 [change] a dry run lists a stale folder and removes nothing
# E2 [change] --apply removes a folder older than the age limit
# E3 [change] ...and keeps a newer one (its process may still be writing)
# E4 [change] ...and keeps anything there not named by a process id
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "zbuild cleanup reclaims stale event-bus folders (#2541)"
setup_test_env "cleanup-ephemeral-events"

ZBUILD="$REPO_ROOT/scripts/zbuild"
D="$TEST_TEMP_DIR/data"; E="$D/ephemeral-events"; FAKE_TMP="$TEST_TEMP_DIR/faketmp"
mkdir -p "$E/111111" "$E/222222" "$E/keep-me" "$FAKE_TMP"
printf '{}\n' > "$E/111111/events.jsonl"
touch -t 200001010000 "$E/111111" "$E/keep-me"

_run() { ZBUILD_DATA_ROOT="$D" TMPDIR="$FAKE_TMP" "$ZBUILD" cleanup --tmpdirs "$@" --age-hours 1 2>&1; }

_out="$(_run --dry-run)"
assert_contains "[E1] the dry run lists the stale folder" "$_out" "$E/111111"
assert_eq "[E1] ...and removes nothing" "1" "$([[ -d "$E/111111" ]] && echo 1 || echo 0)"

_run --apply >/dev/null
assert_eq "[E2] --apply removes the stale folder" "0" "$([[ -d "$E/111111" ]] && echo 1 || echo 0)"
assert_eq "[E3] ...keeps the new one" "1" "$([[ -d "$E/222222" ]] && echo 1 || echo 0)"
assert_eq "[E4] ...keeps one not named by a process id" "1" "$([[ -d "$E/keep-me" ]] && echo 1 || echo 0)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
