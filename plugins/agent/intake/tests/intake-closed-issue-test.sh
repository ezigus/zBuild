#!/usr/bin/env bash
# Tests: plugins/agent/intake — refuse-on-closed (ADR-015, #456). Split from
# intake-test.sh (#1837); the process-boundary copy of the refusal lives in
# tests/integration/intake-refuse-on-closed-subprocess-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake — refuse-on-closed issues (#456)"
setup_test_env "plugin-intake-closed"

# shellcheck source=intake-test-lib.sh
source "$SCRIPT_DIR/intake-test-lib.sh"

# ════════════════════════════════════════════════════════════════════════════
# Issue #456 — refuse-on-closed tests (T_456_a..j)
# ════════════════════════════════════════════════════════════════════════════

_reset_events() {
    : > "$ZBUILD_EVENTS_JSONL"
}

unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="$_ZB_ID"

# ─── T_456_a: CLOSED/COMPLETED → refuse rc=2, event emitted ─────────────────
_set_gh_mock "Should not be read" "body" 0 CLOSED COMPLETED
_reset_events

set +e
t456a_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1837/SPEC-1] T_456_a: CLOSED/COMPLETED returns rc=1" "1" "$rc"
assert_contains "T_456_a: stderr mentions the issue" "$t456a_err" "#$_ZB_ID"
assert_contains "T_456_a: stderr mentions CLOSED" "$t456a_err" "CLOSED"
assert_contains "T_456_a: stderr mentions COMPLETED" "$t456a_err" "COMPLETED"
assert_contains "T_456_a: stderr mentions ZBUILD_ALLOW_CLOSED_ISSUE" \
    "$t456a_err" "ZBUILD_ALLOW_CLOSED_ISSUE"
assert_contains "T_456_a: stderr contains issue URL" \
    "$t456a_err" "github.com/acme/zbuild/issues/$_ZB_ID"
refused_count=$(grep -c '"intake.refused.issue_closed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "T_456_a: intake.refused.issue_closed event emitted" "$refused_count" "0"
state_reason_field="$(grep '"intake.refused.issue_closed"' "$ZBUILD_EVENTS_JSONL" \
    | jq -r 'select(.type=="intake.refused.issue_closed") | .data.state_reason // empty' | tail -1)"
assert_eq "T_456_a: event has state_reason=COMPLETED" "COMPLETED" "$state_reason_field"
assert_file_exists "[#1837/SPEC-2] T_456_a: intake-result.json written on closed-issue refusal" \
    "$ARTIFACT_DIR/intake-result.json"

# ─── T_456_b: CLOSED/NOT_PLANNED ────────────────────────────────────────────
_set_gh_mock "x" "y" 0 CLOSED NOT_PLANNED
_reset_events

set +e
t456b_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1837/SPEC-1] T_456_b: CLOSED/NOT_PLANNED returns rc=1" "1" "$rc"
assert_contains "T_456_b: stderr mentions NOT_PLANNED" "$t456b_err" "NOT_PLANNED"

# ─── T_456_c: CLOSED/DUPLICATE ──────────────────────────────────────────────
_set_gh_mock "x" "y" 0 CLOSED DUPLICATE
_reset_events

set +e
t456c_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1837/SPEC-1] T_456_c: CLOSED/DUPLICATE returns rc=1" "1" "$rc"
assert_contains "T_456_c: stderr mentions DUPLICATE" "$t456c_err" "DUPLICATE"

# ─── T_456_d: CLOSED with empty stateReason ─────────────────────────────────
_set_gh_mock "x" "y" 0 CLOSED ""
_reset_events

set +e
t456d_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1837/SPEC-1] T_456_d: CLOSED/empty-reason returns rc=1" "1" "$rc"
assert_contains "T_456_d: stderr says <not specified>" "$t456d_err" "<not specified>"
if grep -q 'reason: null' <<< "$t456d_err"; then
    assert_fail "T_456_d: stderr must not literal-contain 'reason: null'"
else
    assert_pass "T_456_d: stderr does not contain literal 'reason: null'"
fi
if grep -q '(null)' <<< "$t456d_err"; then
    assert_fail "T_456_d: stderr must not contain '(null)'"
else
    assert_pass "T_456_d: stderr does not contain '(null)'"
fi

# ─── T_456_e: OPEN/REOPENED → pass through, intake.md written ───────────────
_set_gh_mock "Reopened title" "Reopened body" 0 OPEN REOPENED
_reset_events
rm -f "$STATE_DIR/intake.md"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "T_456_e: OPEN/REOPENED returns rc=0" "0" "$rc"
assert_file_exists "T_456_e: intake.md written" "$STATE_DIR/intake.md"
assert_contains "T_456_e: intake.md has title" \
    "$(cat "$STATE_DIR/intake.md")" "Reopened title"
assert_contains "T_456_e: intake.md has body" \
    "$(cat "$STATE_DIR/intake.md")" "Reopened body"

# ─── T_456_f: OPEN with null/empty stateReason ──────────────────────────────
_set_gh_mock "Open title" "Open body" 0 OPEN ""
_reset_events
rm -f "$STATE_DIR/intake.md"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "T_456_f: OPEN/null-reason returns rc=0" "0" "$rc"
assert_file_exists "T_456_f: intake.md written" "$STATE_DIR/intake.md"

# ─── T_456_g: override ZBUILD_ALLOW_CLOSED_ISSUE=1 + CLOSED ─────────────────
_set_gh_mock "Allowed title" "Allowed body" 0 CLOSED COMPLETED
_reset_events
rm -f "$STATE_DIR/intake.md"
export ZBUILD_ALLOW_CLOSED_ISSUE=1

set +e
t456g_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

unset ZBUILD_ALLOW_CLOSED_ISSUE
assert_eq "T_456_g: override + CLOSED returns rc=0" "0" "$rc"
assert_contains "T_456_g: stderr warn mentions ZBUILD_ALLOW_CLOSED_ISSUE" \
    "$t456g_err" "ZBUILD_ALLOW_CLOSED_ISSUE"
assert_file_exists "T_456_g: intake.md written" "$STATE_DIR/intake.md"
assert_contains "T_456_g: intake.md has fetched title" \
    "$(cat "$STATE_DIR/intake.md")" "Allowed title"
override_count=$(grep -c '"intake.override.closed_issue_allowed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "T_456_g: override event emitted" "$override_count" "0"

# ─── T_456_h: INVERTED — =true does NOT bypass; refusal still fires ─────────
_set_gh_mock "x" "y" 0 CLOSED COMPLETED
_reset_events
export ZBUILD_ALLOW_CLOSED_ISSUE=true

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

unset ZBUILD_ALLOW_CLOSED_ISSUE
assert_eq "[#1837/SPEC-1] T_456_h: ZBUILD_ALLOW_CLOSED_ISSUE=true STILL refuses rc=1 (strict =1)" "1" "$rc"

# ─── T_456_i: gh issue view rc=1 → the STATE check falls through ────────────
# What this case is about is the state check: an unreadable issue must not be
# refused as if it were CLOSED. #1804 changed what happens next — the run now
# fails closed on the missing goal rather than fabricating one — so the
# assertion moves to the message, which is what distinguishes "could not read
# the issue" from "refused a closed issue". Asserting rc alone would no longer
# tell those two apart.
_set_gh_mock "" "" 1
_reset_events
rm -f "$STATE_DIR/intake.md"

set +e
t456i_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1837/SPEC-1] T_456_i: gh fail → intake fails closed on the goal rc=1 (#1804)" "1" "$rc"
assert_contains "T_456_i: and it is the FETCH failure, not a closed-issue refusal" \
    "$t456i_err" "could not read issue"
grep -qiE 'closed|not in an actionable state' <<< "$t456i_err" \
    && assert_fail "T_456_i: the state check did NOT refuse it" "$t456i_err" \
    || assert_pass "T_456_i: the state check passed it through"

# And with the opt-in, the fall-through still yields the placeholder it used to.
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_INTAKE_ALLOW_PLACEHOLDER=1 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T_456_i: opt-in restores the pass-through path, rc=0" "0" "$rc"
assert_contains "T_456_i: intake.md has placeholder under the opt-in" \
    "$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)" "GitHub issue #$_ZB_ID"

# ─── T_456_j: MOCK_GH_REPO_RC=1 + CLOSED still refuses cleanly ──────────────
_set_gh_mock "x" "y" 0 CLOSED COMPLETED
export MOCK_GH_REPO_RC=1
_reset_events

set +e
t456j_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

unset MOCK_GH_REPO_RC
assert_eq "[#1837/SPEC-1] T_456_j: repo view fail + CLOSED returns rc=1" "1" "$rc"
assert_contains "T_456_j: stderr still mentions CLOSED" "$t456j_err" "CLOSED"
if grep -q '//issues/' <<< "$t456j_err"; then
    assert_fail "T_456_j: stderr must not contain malformed //issues/ token"
else
    assert_pass "T_456_j: stderr has no malformed //issues/ token"
fi


_clear_gh_mock


# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
