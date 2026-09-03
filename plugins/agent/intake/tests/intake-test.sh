#!/usr/bin/env bash
# Tests: plugins/agent/intake — goal capture, sentinel sanitization, scope manifest (issue #85)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake (goal capture + scope manifest — issue #85)"

setup_test_env "plugin-intake"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Issue #484: branch creation requires a real git repo. These tests use a
# fake state dir, so opt out — dedicated tests in intake-branch-test.sh
# and tests/integration/intake-branch-creation-test.sh cover the new path.
export ZBUILD_INTAKE_SKIP_BRANCH=1

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/intake"

# ─── Fake state file (intake reads dirname to find platforms.json) ────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"0","stage_statuses":{}}' > "$STATE_FILE"

# ─── Test 1: manifest validates + plugin is discoverable ─────────────────────
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "intake manifest validates" "0" "$rc"

discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "intake discovered in plugin registry" "$discovered" "agent/intake"

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../../../plugins/agent/intake/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Test 1b: manifest declares outputs[] with scope-manifest.md first ────────
first_output="$(awk '
    /^outputs:/ { in_outputs=1; next }
    in_outputs && /^[a-zA-Z_]/ { in_outputs=0 }
    in_outputs && /path:/ {
        sub(/^[[:space:]]*path:[[:space:]]*/, "")
        sub(/[[:space:]]*#.*/, "")
        gsub(/^["'"'"']|["'"'"']$/, "")
        print; exit
    }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
assert_contains "intake manifest outputs[0].path contains scope-manifest.md" \
    "$first_output" "scope-manifest.md"

# ─── Test 2: ZBUILD_GOAL unset AND no issue → rc=2 ───────────────────────────
unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="0"

set +e
err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "unset ZBUILD_GOAL with no issue returns rc=2" "2" "$rc"
assert_contains "stderr mentions ZBUILD_GOAL" "$err" "ZBUILD_GOAL"

# ─── Test 3: goal written to state/intake.md ─────────────────────────────────
export ZBUILD_GOAL="fix auth bug"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "valid run returns rc=0" "0" "$rc"
assert_file_exists "state/intake.md created" "$STATE_DIR/intake.md"
assert_contains "intake.md contains sanitized goal" "$(cat "$STATE_DIR/intake.md")" "fix auth bug"

# ─── Test 4: synthesized sentinel stripped from goal ─────────────────────────
ZBUILD_GOAL="$(printf 'fix the login flow\n\n## Plan Summary\nsome noise')"
export ZBUILD_GOAL

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "sentinel-strip run returns rc=0" "0" "$rc"
intake_content="$(cat "$STATE_DIR/intake.md")"
assert_contains "intake.md has original prefix" "$intake_content" "fix the login flow"
if grep -q "Plan Summary" <<< "$intake_content"; then
    assert_fail "sentinel ## Plan Summary should be stripped from intake.md"
else
    assert_pass "sentinel ## Plan Summary stripped from intake.md"
fi

# ─── Test 5: platforms.json drives scope-manifest lines ──────────────────────
cat > "$STATE_DIR/platforms.json" <<'JSON'
{"detected":["ios","node"],"repo_head_sha":"abc123"}
JSON

export ZBUILD_GOAL="add feature"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "platform-aware run returns rc=0" "0" "$rc"
assert_file_exists "scope-manifest.md created" "$STATE_DIR/scope-manifest.md"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "scope-manifest has + ios/" "$scope" "+ ios/"
assert_contains "scope-manifest has + node/" "$scope" "+ node/"

# Each entry must be a "+" line (format consumed by scope-redaction.sh:73)
plus_lines="$(grep -c '^\+' "$STATE_DIR/scope-manifest.md" || true)"
assert_gt "scope-manifest entries are + lines" "$plus_lines" "0"

# ─── Test 5b: injection guard — invalid platform ID is dropped ───────────────
cat > "$STATE_DIR/platforms.json" <<'JSON'
{"detected":["ios","bad\nvalue","../etc","ok-platform"],"repo_head_sha":"abc"}
JSON

export ZBUILD_GOAL="injection test"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "injection guard run returns rc=0" "0" "$rc"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "valid platform ok-platform written" "$scope" "+ ok-platform/"
if grep -q '\.\.' <<< "$scope"; then
    assert_fail "path traversal should be filtered from scope-manifest"
else
    assert_pass "path traversal filtered from scope-manifest"
fi

# ─── Test 6: no platforms.json → generic fallback (+ ./) ─────────────────────
rm -f "$STATE_DIR/platforms.json"

export ZBUILD_GOAL="fix something"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "generic fallback run returns rc=0" "0" "$rc"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "generic fallback writes + ./" "$scope" "+ ./"

# ─── Test 7: plugin.result event emitted ─────────────────────────────────────
run_complete_count=$(grep -c '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "[SPEC-2] plugin.result event emitted" "$run_complete_count" "0"

plugin_field="$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.result") | .data.plugin // empty' 2>/dev/null | tail -1 || true)"
assert_eq "plugin.result has plugin=intake" "intake" "$plugin_field"

# ─── Test 9: empty ZBUILD_GOAL + ZBUILD_ISSUE=0 → rc=2 ──────────────────────
export ZBUILD_GOAL=""
export ZBUILD_ISSUE="0"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "empty ZBUILD_GOAL with no issue returns rc=2" "2" "$rc"

# ─── gh mock for --issue tests ───────────────────────────────────────────────
# Use the shared mock_binary helper (no string interpolation into the mock
# script — title/body/rc/state/stateReason/repo are read at runtime from env
# vars, so arbitrary content with quotes/backticks/$() is safe). Unrecognized
# invocations exit 2 with a diagnostic so contract drift in the production
# `gh` call fails the test loudly instead of silently succeeding.
#
# Dispatches THREE call shapes (issue #456):
#   1. gh issue view N --json state,stateReason --jq …    → state envelope
#   2. gh issue view N --json title,body --jq …           → title+body (#421)
#   3. gh repo view --json nameWithOwner --jq …           → repo slug
mock_binary "gh" '
case "${1:-} ${2:-}" in
    "issue view")
        # Distinguish the two --json shapes by inspecting field list (${5}).
        if [[ "${4:-}" == "--json" && "${5:-}" == "state,stateReason" ]]; then
            # MOCK_GH_STATE_RC overrides; otherwise inherit MOCK_GH_RC so a
            # single fail-switch (#421 compat) flips both call shapes.
            _rc="${MOCK_GH_STATE_RC:-${MOCK_GH_RC:-0}}"
            if [[ "$_rc" -ne 0 ]]; then
                exit "$_rc"
            fi
            payload="$(jq -nc \
                --arg s "${MOCK_GH_STATE:-OPEN}" \
                --arg r "${MOCK_GH_STATE_REASON:-}" \
                "{state:\$s, stateReason:(if \$r == \"\" then null else \$r end)}")"
            if [[ "${6:-}" == "--jq" ]]; then
                printf "%s" "$payload" | jq -r "$7"
            else
                printf "%s" "$payload"
            fi
            exit 0
        elif [[ "${4:-}" == "--json" && ( "${5:-}" == "title,body" || "${5:-}" == "title,body,comments" ) ]]; then
            if [[ "${MOCK_GH_RC:-0}" -ne 0 ]]; then
                exit "${MOCK_GH_RC}"
            fi
            # #1729: comments ride the same call. MOCK_GH_COMMENTS is a JSON
            # array supplied by the test; absent, it is empty.
            payload="$(jq -nc \
                --arg t "${MOCK_GH_ISSUE_TITLE:-}" \
                --arg b "${MOCK_GH_ISSUE_BODY:-}" \
                --argjson c "${MOCK_GH_COMMENTS:-[]}" \
                "{title:\$t, body:\$b, comments:\$c}")"
            if [[ "${6:-}" == "--jq" ]]; then
                printf "%s" "$payload" | jq -r "$7"
            else
                printf "%s" "$payload"
            fi
            exit 0
        fi
        printf "mock gh: unexpected issue view args: %s\n" "$*" >&2
        exit 2
        ;;
    "repo view")
        if [[ "${MOCK_GH_REPO_RC:-0}" -ne 0 ]]; then
            exit "${MOCK_GH_REPO_RC}"
        fi
        slug="${MOCK_GH_REPO:-acme/zbuild}"
        if [[ "${2:-}" == "view" && "${3:-}" == "--json" && "${5:-}" == "--jq" ]]; then
            printf "%s\n" "$slug"
        else
            printf "{\"nameWithOwner\":\"%s\"}\n" "$slug"
        fi
        exit 0
        ;;
    *)
        printf "mock gh: unexpected args: %s\n" "$*" >&2
        exit 2
        ;;
esac
'

_set_gh_mock() {
    # $1=title $2=body $3=exit-rc [$4=state] [$5=stateReason]
    export MOCK_GH_ISSUE_TITLE="$1"
    export MOCK_GH_ISSUE_BODY="$2"
    export MOCK_GH_RC="$3"
    export MOCK_GH_STATE="${4:-OPEN}"
    export MOCK_GH_STATE_REASON="${5:-}"
    # When tests want the state-check call to also fail, they set MOCK_GH_STATE_RC.
    export MOCK_GH_STATE_RC="${MOCK_GH_STATE_RC:-0}"
}

_clear_gh_mock() {
    unset MOCK_GH_ISSUE_TITLE MOCK_GH_ISSUE_BODY MOCK_GH_RC \
          MOCK_GH_STATE MOCK_GH_STATE_REASON MOCK_GH_STATE_RC \
          MOCK_GH_REPO MOCK_GH_REPO_RC ZBUILD_ALLOW_CLOSED_ISSUE
    rm -f "$TEST_TEMP_DIR/bin/gh"
}

# ─── Test 10: --issue mode fetches real title+body via gh ────────────────────
_set_gh_mock "Fix login crash on launch" $'Steps to reproduce:\n1. Open app\n2. Tap login' 0
unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="$_ZB_ID"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "--issue mode with no goal text returns rc=0" "0" "$rc"
assert_contains "--issue mode writes fetched title to intake.md" \
    "$(cat "$STATE_DIR/intake.md")" "Fix login crash on launch"
assert_contains "--issue mode writes fetched body to intake.md" \
    "$(cat "$STATE_DIR/intake.md")" "Steps to reproduce"

# ─── Test 10b (#1804): a failed fetch FAILS CLOSED ──────────────────────────
# It used to warn and set the goal to the literal "GitHub issue #<N>", then let
# plan, design (up to three cycles), impact, build, test and six review lenses
# all run against a goal carrying NO information about what to build. Every
# other intake failure mode is rc=2; this one was not.
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"

set +e
intake_stderr="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1804] a failed fetch with no supplied goal fails the run" "2" "$rc"
assert_contains "[#1804] and says why, naming the issue" \
    "$intake_stderr" "#$_ZB_ID"
assert_file_not_exists "[#1804] no fabricated goal is left on disk for the pipeline to use" \
    "$STATE_DIR/intake.md"

# ─── Test 10b2 (#1804): the offline placeholder survives, behind an opt-in ──
# A smoke run without network is legitimate — it just has to say so.
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_INTAKE_ALLOW_PLACEHOLDER=1 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[#1804] the opt-in still returns rc=0" "0" "$rc"
assert_contains "[#1804] and writes the placeholder it asked for" \
    "$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)" "GitHub issue #$_ZB_ID"

# ─── Test 10b3 (#1804): an explicit goal works with no network ──────────────
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_GOAL="Explicitly supplied goal text" intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[#1804] an explicit goal needs no fetch at all" "0" "$rc"
assert_contains "[#1804] and is what lands in intake.md" \
    "$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)" "Explicitly supplied goal text"

# ─── Test 10c: null body — title-only fetch is acceptable ───────────────────
_set_gh_mock "Refactor cache layer" "" 0

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "title-only fetch returns rc=0" "0" "$rc"
assert_contains "title-only intake.md contains title" \
    "$(cat "$STATE_DIR/intake.md")" "Refactor cache layer"

# NOTE: do not _clear_gh_mock here — T_456_* tests reuse the gh PATH shim.

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

assert_eq "T_456_a: CLOSED/COMPLETED returns rc=2" "2" "$rc"
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

# ─── T_456_b: CLOSED/NOT_PLANNED ────────────────────────────────────────────
_set_gh_mock "x" "y" 0 CLOSED NOT_PLANNED
_reset_events

set +e
t456b_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T_456_b: CLOSED/NOT_PLANNED returns rc=2" "2" "$rc"
assert_contains "T_456_b: stderr mentions NOT_PLANNED" "$t456b_err" "NOT_PLANNED"

# ─── T_456_c: CLOSED/DUPLICATE ──────────────────────────────────────────────
_set_gh_mock "x" "y" 0 CLOSED DUPLICATE
_reset_events

set +e
t456c_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T_456_c: CLOSED/DUPLICATE returns rc=2" "2" "$rc"
assert_contains "T_456_c: stderr mentions DUPLICATE" "$t456c_err" "DUPLICATE"

# ─── T_456_d: CLOSED with empty stateReason ─────────────────────────────────
_set_gh_mock "x" "y" 0 CLOSED ""
_reset_events

set +e
t456d_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T_456_d: CLOSED/empty-reason returns rc=2" "2" "$rc"
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
assert_eq "T_456_h: ZBUILD_ALLOW_CLOSED_ISSUE=true STILL refuses (strict =1)" "2" "$rc"

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

assert_eq "T_456_i: gh fail → intake fails closed on the goal (#1804)" "2" "$rc"
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
assert_eq "T_456_j: repo view fail + CLOSED returns rc=2" "2" "$rc"
assert_contains "T_456_j: stderr still mentions CLOSED" "$t456j_err" "CLOSED"
if grep -q '//issues/' <<< "$t456j_err"; then
    assert_fail "T_456_j: stderr must not contain malformed //issues/ token"
else
    assert_pass "T_456_j: stderr has no malformed //issues/ token"
fi

# ─── #1729: issue COMMENTS reach the goal, filtered by author ───────────────
# Comments are where an issue is corrected and extended after filing. #1685 is
# the worked example: its body describes one problem, and a later owner comment
# added a second, independent half. The pipeline was structurally blind to it —
# and the acceptance-gate would have agreed the work was complete, because the
# SPECs it checks derive from the same truncated goal text. Silent scope loss
# with every gate green.
#
# Author filtering is the load-bearing part: zbuild posts its own
# run-completion comments, so an unfiltered append would feed the pipeline's own
# failure log straight back to the planner.
print_test_section "#1729: comments reach the goal, bots and retractions do not"

MOCK_GH_COMMENTS="$(cat <<'CMTS'
[
  {"author":{"login":"ezigus"},"authorAssociation":"OWNER","isMinimized":false,
   "body":"CORRECTION_FROM_OWNER also handle the timeout case"},
  {"author":{"login":"github-actions"},"authorAssociation":"NONE","isMinimized":false,
   "body":"BOTNOISE zbuild pipeline finished with result failed"},
  {"author":{"login":"some-bot[bot]"},"authorAssociation":"CONTRIBUTOR","isMinimized":false,
   "body":"BRACKETBOTNOISE automated message"},
  {"author":{"login":"ezigus"},"authorAssociation":"OWNER","isMinimized":true,
   "body":"RETRACTEDCOMMENT this was wrong"},
  {"author":{"login":"a-collaborator"},"authorAssociation":"COLLABORATOR","isMinimized":false,
   "body":"COLLABORATOR_ADDITION and refuse an empty config"}
]
CMTS
)"
export MOCK_GH_COMMENTS
_set_gh_mock "Fix login crash on launch" "Steps to reproduce click login" 0
rm -f "$STATE_DIR/intake.md"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
_c_goal="$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)"

assert_eq "[#1729] the fetch still succeeds" "0" "$rc"
assert_contains "[#1729] an OWNER comment reaches the goal" \
    "$_c_goal" "CORRECTION_FROM_OWNER"
assert_contains "[#1729] a COLLABORATOR comment reaches it too" \
    "$_c_goal" "COLLABORATOR_ADDITION"
assert_contains "[#1729] under a labelled heading, not silently concatenated" \
    "$_c_goal" "Additional context from issue comments"
assert_eq "[#1729] a github-actions comment does NOT — it is the pipeline's own log" \
    "0" "$(grep -c 'BOTNOISE' <<< "$_c_goal" || true)"
assert_eq "[#1729] nor any [bot] login" \
    "0" "$(grep -c 'BRACKETBOTNOISE' <<< "$_c_goal" || true)"
assert_eq "[#1729] nor a minimized comment — minimizing is an explicit retraction" \
    "0" "$(grep -c 'RETRACTEDCOMMENT' <<< "$_c_goal" || true)"
assert_contains "[#1729] and the body itself survives" "$_c_goal" "Steps to reproduce"

# ─── #1729: growth is bounded, and truncation SAYS so ──────────────────────
# The goal feeds the redaction chokepoint and every downstream prompt, so an
# unbounded comment thread inflates every stage. Silent truncation would be the
# worse failure: a shortened goal that still reads as complete.
_big_body="$(python3 -c 'print("X"*9000)')"
MOCK_GH_COMMENTS="$(jq -nc --arg b "$_big_body" \
    '[{author:{login:"ezigus"},authorAssociation:"OWNER",isMinimized:false,body:$b}]')"
export MOCK_GH_COMMENTS
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_INTAKE_COMMENT_MAX_BYTES=500 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
_t_goal="$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)"
assert_eq "[#1729] the comment section is capped" \
    "1" "$([[ "${#_t_goal}" -lt 9000 ]] && echo 1 || echo 0)"
assert_contains "[#1729] and the truncation is STATED, not silent" \
    "$_t_goal" "truncated"
unset MOCK_GH_COMMENTS

_clear_gh_mock

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
