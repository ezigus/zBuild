#!/usr/bin/env bash
# plugins/agent/intake/tests/intake-test-lib.sh — the environment every intake
# test file shares: identity, event sinks, a fake state dir with the engine's
# artifact dir, the plugin loaded, and the `gh` mock. Sourced AFTER helpers,
# test-helpers and setup_test_env (it writes under $TEST_TEMP_DIR).
# shellcheck disable=SC2034  # the variables are read by the sourcing test file

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

# Artifact dir for SPEC-2/3/9/15 result file checks (ZBUILD_ARTIFACT_DIR set
# early so every intake_run in this file writes its result here)
ARTIFACT_DIR="$STATE_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../../../plugins/agent/intake/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

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

