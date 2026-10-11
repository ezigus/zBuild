#!/usr/bin/env bash
# tests/unit/run-status-retry-row-test.sh — a stage that fails and then passes
# on a retry shows its last result in the run-status comment (ADR-064 §2).
#
# Why: in #1668's run (20261010132454-2484) plan's first try failed a schema
# check and the engine ran it again under the same row number. The retry passed
# and the run went on, but the comment still showed plan as "error": the row
# was closed by the first try, the retry's start was ignored because the row
# already existed, and the retry's pass found no open row to close.
#
# T1 [code] fail, then a retry that passes → the row shows pass
# T2 [code] the retry's start time is the row's start; one row, not two
# T3 [code] a repeated start for a row still running changes nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "run-status comment — a retried stage shows its last result (ADR-064 §2)"
setup_test_env "run-status-retry-row"
_test_cleanup_hook() { cleanup_test_env; }

# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"

EV="$TEST_TEMP_DIR/events.jsonl"
# The envelopes core/event-bus/event-bus.sh wrote in #1668's run, in order,
# trimmed to the fields the renderer reads.
cat > "$EV" <<'EOF'
{"ts":"2026-10-10T13:25:07.346Z","run_id":"r","issue":1668,"type":"stage.start","plugin":"","kind":"","data":{"stage":"plan"},"schema_version":1}
{"ts":"2026-10-10T13:25:07.946Z","run_id":"r","issue":1668,"type":"plugin.run.start","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:27:42.095Z","run_id":"r","issue":1668,"type":"plugin.result","plugin":"plan","kind":"agent","data":{"verdict":"error","plugin":"plan","reason":"schema_violation"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:27:42.113Z","run_id":"r","issue":1668,"type":"plugin.run.error","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent","rc":"1"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:27:42.857Z","run_id":"r","issue":1668,"type":"plugin.run.start","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:29:01.177Z","run_id":"r","issue":1668,"type":"plugin.result","plugin":"plan","kind":"agent","data":{"stage":"plan","plugin":"plan","artifact":"plan.json"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:29:02.442Z","run_id":"r","issue":1668,"type":"plugin.run.complete","plugin":"plan","kind":"agent","data":{"plugin":"plan","kind":"agent"},"schema_version":1,"stage":"plan","seq":"3"}
{"ts":"2026-10-10T13:29:02.813Z","run_id":"r","issue":1668,"type":"stage.complete","plugin":"","kind":"","data":{"stage":"plan","verdict":"pass"},"schema_version":1}
EOF
_rows="$(rsc_rows_json "$EV")"
assert_eq "[T1] the retried stage's row shows pass" "pass" "$(jq -r '.rows["3"].verdict // "none"' <<< "$_rows")"
assert_eq "[T1] ...with no leftover error code" "null" "$(jq -r '.rows["3"].rc' <<< "$_rows")"
assert_eq "[T2] one row for the stage" "1" "$(jq -r '.order | length' <<< "$_rows")"
assert_eq "[T2] the row starts at the retry" "2026-10-10T13:27:42.857Z" "$(jq -r '.rows["3"].started_ts' <<< "$_rows")"
assert_eq "[T2] the row ends at the retry's end" "2026-10-10T13:29:02.813Z" "$(jq -r '.rows["3"].ended_ts' <<< "$_rows")"

EV3="$TEST_TEMP_DIR/events3.jsonl"
head -n 2 "$EV" > "$EV3"
sed -n 2p "$EV" | sed 's/13:25:07.946Z/13:26:00.000Z/' >> "$EV3"
_r3="$(rsc_rows_json "$EV3")"
assert_eq "[T3] a repeated start while running keeps the first start" "2026-10-10T13:25:07.946Z" \
    "$(jq -r '.rows["3"].started_ts' <<< "$_r3")"
assert_eq "[T3] ...and the row is still running" "null" "$(jq -r '.rows["3"].verdict' <<< "$_r3")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
