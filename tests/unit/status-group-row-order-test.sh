#!/usr/bin/env bash
# tests/unit/status-group-row-order-test.sh — a group's summary row follows its
# members in the run-status comment (#2598 R6, ADR-064).
#
# #2532 run 45231040380: "3.1.2 review_lenses — all 6 lenses finished" started a
# moment before its six lenses, so it sorted as the oldest of them: read in
# time order, the summary came before the lenses it summarises.
#
# G1 [change] the group's row comes after every one of its members in the
#             order rows are kept (the comment shows the newest at the top, so
#             the summary is shown above the lenses it summarises)
# G2 [guard]  a row that is no group keeps its place
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a group's summary row follows its members (#2598)"
setup_test_env "status-group-row-order"
# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"

EV="$TEST_TEMP_DIR/events.jsonl"
_e() { printf '{"ts":"2026-11-23T18:%s.000Z","run_id":"r","issue":2532,"type":"%s","stage":"%s","seq":"%s","data":%s,"schema_version":1}\n' "$1" "$2" "$3" "$4" "${5:-{\}}"; }
{
    _e 13:00 plugin.run.start issue-acceptance 3.1.1.1.5
    _e 14:00 plugin.run.complete issue-acceptance 3.1.1.1.5
    _e 14:01 parallel.group.start review_lenses 3.1.2
    _e 14:02 plugin.run.start review_lenses 3.1.2.1
    _e 14:02 plugin.run.start review_lenses 3.1.2.2
    _e 16:00 parallel.member.dispatch.complete review_lenses 3.1.2.1 '{"member":"review_lenses.security","verdict":"pass"}'
    _e 19:00 parallel.member.dispatch.complete review_lenses 3.1.2.2 '{"member":"review_lenses.scope","verdict":"fail"}'
    _e 23:00 parallel.group.complete review_lenses 3.1.2 '{"verdict":"fail"}'
} > "$EV"
_o="$(rsc_rows_json "$EV" | jq -r '.order | join(" ")')"
_pos() { local i=0 k; for k in $_o; do [[ "$k" == "$1" ]] && { printf '%s' "$i"; return; }; i=$((i + 1)); done; printf -- '-1'; }
assert_eq "[G1] setup: the group and both members have rows" "yes" \
    "$([[ $(_pos 3.1.2) -ge 0 && $(_pos 3.1.2.1) -ge 0 && $(_pos 3.1.2.2) -ge 0 ]] && echo yes || echo no)"
assert_eq "[G1] the group's row follows both its members" "yes" \
    "$([[ $(_pos 3.1.2) -gt $(_pos 3.1.2.1) && $(_pos 3.1.2) -gt $(_pos 3.1.2.2) ]] && echo yes || echo no)"
assert_eq "[G2] a stage before the group keeps its place: first" "0" "$(_pos 3.1.1.1.5)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
