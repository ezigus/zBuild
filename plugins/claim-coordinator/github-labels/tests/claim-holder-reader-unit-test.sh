#!/usr/bin/env bash
# Tests: who holds a claim, written into the run-status comment and read back
# from it (ADR-005 §2). The comment bodies are made by the writer's own code
# (eb_emit_event → rsc_rows_json → rsc_render_header), never by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../../../tests/lib/claim-gh-mock.sh
source "$REPO_ROOT/tests/lib/claim-gh-mock.sh"
# shellcheck source=../../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"

print_test_header "plugin: claim-coordinator/github-labels — the holder, written and read"
setup_test_env "claim-holder-reader"
unset NO_GITHUB
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATUS_NOW="2026-01-01T00:05:00Z"

# _body <run_id> [holder] [ended] — the run's comment header as the sidecar
# renders it; the holder rides the event the engine emits when it has the claim,
# and a third argument ends the run (pipeline.end).
_body() {
    local ev="$TEST_TEMP_DIR/ev-$1.jsonl"; : > "$ev"
    ZBUILD_EVENTS_JSONL="$ev" ZBUILD_RUN_ID="$1" ZBUILD_ISSUE=90001851 eb_emit_event pipeline.start "run_id=$1" "issue=90001851" 2>/dev/null
    if [[ -n "${2:-}" ]]; then
        ZBUILD_EVENTS_JSONL="$ev" ZBUILD_RUN_ID="$1" ZBUILD_ISSUE=90001851 eb_emit_event pipeline.claim.acquired "holder=$2" 2>/dev/null
    fi
    if [[ -n "${3:-}" ]]; then
        ZBUILD_EVENTS_JSONL="$ev" ZBUILD_RUN_ID="$1" ZBUILD_ISSUE=90001851 eb_emit_event pipeline.end "status=success" 2>/dev/null
    fi
    rsc_render_header "$(rsc_rows_json "$ev")" "$TEST_TEMP_DIR" || true
}

print_test_section "the writer: the holder line only while a run that has the claim is running"
hdr="$(_body run-a "run_id=run-a machine=box-1")"
assert_contains "a run with the claim names its holder in the header" "$hdr" \
    "<!-- zbuild-holder: run_id=run-a machine=box-1 -->"
hdr="$(_body run-b)"
if [[ "$hdr" == *"zbuild-holder"* ]]; then
    assert_fail "a run without the claim names no holder" "$hdr"
else
    assert_pass "a run without the claim names no holder"
fi
hdr="$(_body run-c "run_id=run-c machine=box-1" ended)"
if [[ "$hdr" == *"zbuild-holder"* ]]; then
    assert_fail "a finished run names no holder" "$hdr"
else
    assert_pass "a finished run names no holder"
fi

# ── the reader (gh backend) ──────────────────────────────────────────────────
export ZBUILD_CLAIM_BACKEND="gh" GITHUB_REPOSITORY="testowner/testrepo"
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
GHS="$TEST_TEMP_DIR/gh"; claim_gh_mock_install "$GHS"
# shellcheck source=../plugin.sh
source "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"

old_owner="$(_body run-old "run_id=run-old machine=box-old")"
bot_holder="https://github.com/testowner/testrepo/actions/runs/555"
bot_body="$(_body run-ci "$bot_holder")"
spoof_body="$(_body run-evil "run_id=evil machine=spoofed")"
jq -n --arg b "$old_owner" '[
    {id:1, user:{login:"someone-else"}, author_association:"NONE", body:"nice work"},
    {id:2, user:{login:"maintainer"}, author_association:"OWNER", body:$b}]' > "$GHS/page-1.json"
jq -n --arg b "$bot_body" --arg s "$spoof_body" '[
    {id:3, user:{login:"github-actions[bot]"}, author_association:"NONE", body:$b},
    {id:4, user:{login:"someone"}, author_association:"NONE", body:null},
    {id:5, user:{login:"evil"}, author_association:"NONE", body:$s}]' > "$GHS/page-2.json"

print_test_section "the reader"
got="$(_ccgl_read_holder 90001851 2>/dev/null || true)"
assert_eq "the newest trusted run-status comment names the holder — on page 2, by the CI bot" "$bot_holder" "$got"
assert_contains "…the comments were read with --paginate" "$(cat "$GHS/log")" "api --paginate repos/testowner/testrepo/issues/90001851/comments"

finished_body="$(_body run-done "run_id=run-done machine=box-2" ended)"
live_body="$(_body run-live)"
jq -n --arg f "$finished_body" --arg l "$live_body" '[
    {id:1, user:{login:"maintainer"}, author_association:"OWNER", body:$f},
    {id:2, user:{login:"maintainer"}, author_association:"OWNER", body:$l}]' > "$GHS/page-1.json"
rm -f "$GHS/page-2.json"
got="$(_ccgl_read_holder 90001851 2>/dev/null || true)"
assert_eq "the newest run-status comment names no holder → none, never an older one" "" "$got"
jq -n --arg f "$(_body run-done2 "run_id=run-done2 machine=box-2")" --arg l "$finished_body" '[
    {id:1, user:{login:"maintainer"}, author_association:"OWNER", body:$f},
    {id:2, user:{login:"maintainer"}, author_association:"OWNER", body:$l}]' > "$GHS/page-1.json"
got="$(_ccgl_read_holder 90001851 2>/dev/null || true)"
assert_eq "the newest run-status comment is a finished run's → no holder" "" "$got"

jq -n --arg s "$spoof_body" '[
    {id:1, user:{login:"evil"}, author_association:"NONE", body:$s},
    {id:2, user:{login:"someone"}, author_association:"CONTRIBUTOR", body:null}]' > "$GHS/page-1.json"
got="$(_ccgl_read_holder 90001851 2>/dev/null || true)"
assert_eq "an outside commenter cannot name the holder" "" "$got"

print_test_section "the local-fs store reads the holder line with the same reader"
export ZBUILD_CLAIM_BACKEND=local-fs ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/store"
mkdir -p "$ZBUILD_CLAIM_STORE/90001851"; printf '%s\n' "$bot_body" > "$ZBUILD_CLAIM_STORE/90001851/run-status-comment.txt"
assert_eq "the local-fs holder is the comment's holder line" "$bot_holder" "$(_ccgl_read_holder 90001851)"
assert_eq "the line has one reader, next to its prefix" "1" \
    "$(/usr/bin/grep -c 'zbuild-holder' "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh" "$REPO_ROOT/scripts/lib/run-status-comment.sh" | awk -F: '{ n += $2 } END { print (n == 0) }')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
