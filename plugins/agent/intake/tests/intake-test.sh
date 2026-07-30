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
intake_init >/dev/null 2>&1

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

# ─── Test 7: plugin.run.complete event emitted ───────────────────────────────
run_complete_count=$(grep -c '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "plugin.run.complete event emitted" "$run_complete_count" "0"

plugin_field="$(grep '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.run.complete") | .data.plugin // empty' 2>/dev/null | tail -1 || true)"
assert_eq "plugin.run.complete has plugin=intake" "intake" "$plugin_field"

# ─── Test 8: plugin.finalize.complete event after finalize ───────────────────
intake_finalize >/dev/null 2>&1

finalize_count=$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "plugin.finalize.complete event emitted" "$finalize_count" "0"

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
        elif [[ "${4:-}" == "--json" && "${5:-}" == "title,body" ]]; then
            if [[ "${MOCK_GH_RC:-0}" -ne 0 ]]; then
                exit "${MOCK_GH_RC}"
            fi
            payload="$(jq -nc \
                --arg t "${MOCK_GH_ISSUE_TITLE:-}" \
                --arg b "${MOCK_GH_ISSUE_BODY:-}" \
                "{title:\$t, body:\$b}")"
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
export ZBUILD_ISSUE="42"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "--issue mode with no goal text returns rc=0" "0" "$rc"
assert_contains "--issue mode writes fetched title to intake.md" \
    "$(cat "$STATE_DIR/intake.md")" "Fix login crash on launch"
assert_contains "--issue mode writes fetched body to intake.md" \
    "$(cat "$STATE_DIR/intake.md")" "Steps to reproduce"

# ─── Test 10b: gh failure falls back to placeholder + warns ─────────────────
_set_gh_mock "" "" 1

set +e
intake_stderr="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "gh failure still returns rc=0 (placeholder fallback)" "0" "$rc"
assert_contains "fallback intake.md contains placeholder issue ref" \
    "$(cat "$STATE_DIR/intake.md")" "GitHub issue #42"
assert_contains "gh failure emits visible warn" \
    "$intake_stderr" "gh issue view #42 failed"

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
export ZBUILD_ISSUE="42"

# ─── T_456_a: CLOSED/COMPLETED → refuse rc=2, event emitted ─────────────────
_set_gh_mock "Should not be read" "body" 0 CLOSED COMPLETED
_reset_events

set +e
t456a_err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T_456_a: CLOSED/COMPLETED returns rc=2" "2" "$rc"
assert_contains "T_456_a: stderr mentions #42" "$t456a_err" "#42"
assert_contains "T_456_a: stderr mentions CLOSED" "$t456a_err" "CLOSED"
assert_contains "T_456_a: stderr mentions COMPLETED" "$t456a_err" "COMPLETED"
assert_contains "T_456_a: stderr mentions ZBUILD_ALLOW_CLOSED_ISSUE" \
    "$t456a_err" "ZBUILD_ALLOW_CLOSED_ISSUE"
assert_contains "T_456_a: stderr contains issue URL" \
    "$t456a_err" "github.com/acme/zbuild/issues/42"
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

# ─── T_456_i: gh issue view rc=1 → state check falls through, placeholder ───
_set_gh_mock "" "" 1
_reset_events
rm -f "$STATE_DIR/intake.md"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "T_456_i: gh fail → state check passes through, rc=0" "0" "$rc"
assert_contains "T_456_i: intake.md has placeholder" \
    "$(cat "$STATE_DIR/intake.md")" "GitHub issue #42"

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

_clear_gh_mock

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
