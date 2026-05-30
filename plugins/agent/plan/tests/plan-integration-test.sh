#!/usr/bin/env bash
# Integration test: plan stage end-to-end with a stubbed `claude` binary on PATH.
# Exercises route_to_model -> _route_call_claude across the subprocess boundary
# (real subshell, real exec) and verifies the scope post-validation contract
# from ADR-018 Pattern 1 (#468).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — integration (real claude stub, subprocess boundary)"

setup_test_env "plugin-plan-integration"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/plan"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"999","stage_statuses":{}}' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

export ZBUILD_GOAL="integration test goal"
export ZBUILD_RUN_ID="integ-test"
export ZBUILD_ISSUE=999

# Stub a real `claude` binary on PATH. route_to_model -> _route_call_claude
# resolves it via `command -v claude` and then execs it.
#
# #476: envelope-aware via the shared helper. Plan now exports
# ZBUILD_ROUTER_JSON_OUTPUT=1 (ADR-018 Pattern 1 decision #8), so the router
# adds --output-format json. The helper wraps in envelope on that argv;
# otherwise emits raw.
CANNED_RESPONSE_FILE="$TEST_TEMP_DIR/claude-canned.json"
: > "$CANNED_RESPONSE_FILE"
install_envelope_mock_claude --file "$CANNED_RESPONSE_FILE"

# Source plugin
# shellcheck source=../../../../plugins/agent/plan/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Variant 1: in-scope plan → plan.json written, no violations ─────────────
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$CANNED_RESPONSE_FILE"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "variant 1: in-scope plan returns rc=0" "0" "$rc"
assert_file_exists "variant 1: plan.json written" "$ARTIFACTS_DIR/plan.json"
v1_violations="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "variant 1: no violation events" "0" "$v1_violations"

# ─── Variant 2: out-of-scope plan → plan.json still written, violation emitted ─
: > "$ZBUILD_EVENTS_JSONL"
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["legacy/oops.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$CANNED_RESPONSE_FILE"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "variant 2: out-of-scope returns rc=0 (fail-soft)" "0" "$rc"
assert_file_exists "variant 2: plan.json still written" "$ARTIFACTS_DIR/plan.json"
v2_violations="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "variant 2: one violation event" "1" "$v2_violations"
v2_path="$(jq -r 'select(.type=="plan.scope.violation") | .data.path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "variant 2: violation path is offender" "legacy/oops.sh" "$v2_path"

# ─── Variant 3 (#478): prose-prefixed JSON survives the subprocess boundary ─
# The mock claude returns prose preface + JSON inside the envelope .result.
# The parser-side helper (extract_first_json_object) must slice the JSON out
# before jq -e validation; otherwise the dogfood failure path reproduces here.
: > "$ZBUILD_EVENTS_JSONL"
printf 'Now I have a complete picture.\n\n%s\n' \
    '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' \
    > "$CANNED_RESPONSE_FILE"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "variant 3 (#478): prose-prefixed envelope returns rc=0" "0" "$rc"
assert_file_exists "variant 3 (#478): plan.json written despite prose preface" \
    "$ARTIFACTS_DIR/plan.json"
v3_schema="$(jq -r '.schema_version // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "variant 3 (#478): plan.json parsed via parser-side helper" "1" "$v3_schema"
v3_violations="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "variant 3 (#478): no scope violations on in-scope payload" "0" "$v3_violations"

# ─── Variant 4 (#483): producer-side OUTPUT banner renders markdown ──────────
# When plan opts into ZBUILD_ROUTER_ARTIFACT_ID=plan, the router appends
# metadata.artifact=plan to capture_stage_io. The stage-io output branch now
# dispatches render_plan_md, so plan's own banner shows "# Plan: ..." instead
# of raw JSON.
: > "$ZBUILD_EVENTS_JSONL"
printf '%s\n' '{"schema_version":1,"title":"Banner Title","goal":"render output banner","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$CANNED_RESPONSE_FILE"

# Enable stage-io capture for the "plan" stage with stdout destination.
# The template-loader exports _TPL_STAGE_IO_DESTS_<safe_id> when a template
# is loaded; we set it directly here to bypass needing a full template load.
export ZBUILD_CURRENT_STAGE=plan
export _TPL_STAGE_IO_DESTS_plan="stdout"
# Capture the stage-io banner: open fd 3 to a file.
BANNER_OUT="$TEST_TEMP_DIR/banner-v4.txt"
: > "$BANNER_OUT"
exec 3>"$BANNER_OUT"
export ZBUILD_STAGE_IO_FD=3

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_plan

assert_eq "variant 4 (#483): plan_run still rc=0 with banner capture on" "0" "$rc"
banner_content="$(cat "$BANNER_OUT" 2>/dev/null || true)"
if printf '%s' "$banner_content" | grep -qF "# Plan: Banner Title"; then
    assert_pass "variant 4 (#483): OUTPUT banner contains rendered markdown heading"
else
    assert_fail "variant 4 (#483): OUTPUT banner missing markdown heading" \
        "got: $(printf '%s' "$banner_content" | head -40)"
fi
# The output banner section must not contain the raw JSON title key.
banner_output_section="$(printf '%s' "$banner_content" | sed -n '/── output ──/,/── end stage-io/p')"
if printf '%s' "$banner_output_section" | grep -qF '"title":"Banner Title"'; then
    assert_fail "variant 4 (#483): raw JSON leaked into output section" \
        "got: $(printf '%s' "$banner_output_section" | head -20)"
else
    assert_pass "variant 4 (#483): raw JSON absent from output section"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
