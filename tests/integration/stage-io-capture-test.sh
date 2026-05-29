#!/usr/bin/env bash
# Tests: end-to-end stage-io capture via router (ADR-015 v1, issue #438).
# Loads a template with io.destinations=[file], invokes route_to_model with
# ZBUILD_CURRENT_STAGE set, and asserts the artifact was written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io capture — end-to-end via router (ADR-015 v1, #438)"
setup_test_env "stage-io-integration"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="run-stage-io-int"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# Operator override token to allow --skip-precondition in this isolated HOME.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "$ZBUILD_RUN_ID" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Canned claude stub
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "CANNED_RESPONSE_BODY"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Load template that has plan stage with io.destinations: [file]
TPL="$TEST_TEMP_DIR/io-template.yaml"
cat > "$TPL" <<'EOF'
id: io-int
name: IO Integration
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
EOF

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$TPL"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# Confirm stage-io.sh got transitively loaded (route.sh sources it).
type capture_stage_io >/dev/null 2>&1 && assert_pass "capture_stage_io loaded via route.sh" \
    || assert_fail "capture_stage_io NOT loaded via route.sh"

# Mark current stage and invoke
export ZBUILD_CURRENT_STAGE="plan"
set +e
out="$(route_to_model "T2" "the test prompt" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "route_to_model rc=0" "0" "$rc"
assert_contains "router returned canned response" "$out" "CANNED_RESPONSE_BODY"

artifact="$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
assert_file_exists "stage-io artifact written" "$artifact"

json="$(cat "$artifact" 2>/dev/null || echo '{}')"
assert_json_key "artifact schema_version=1" "$json" ".schema_version" "1"
assert_json_key "artifact kind=llm" "$json" ".kind" "llm"
assert_json_key "artifact stage=plan" "$json" ".stage" "plan"
assert_contains "artifact input contains prompt" "$(printf '%s' "$json" | jq -r .input)" "the test prompt"
assert_contains "artifact output contains canned response" "$(printf '%s' "$json" | jq -r .output)" "CANNED_RESPONSE_BODY"

# stage.io.captured event recorded
assert_event_emitted "stage.io.captured event emitted" "$ZBUILD_EVENTS_JSONL" "stage.io.captured"

# When ZBUILD_CURRENT_STAGE is unset → no capture, no failure
unset ZBUILD_CURRENT_STAGE
rm -f "$artifact"
set +e
out2="$(route_to_model "T2" "no stage prompt" --skip-precondition 2>/dev/null)"
rc2=$?
set -e
assert_eq "route_to_model still rc=0 without stage" "0" "$rc2"
assert_file_not_exists "no artifact written when ZBUILD_CURRENT_STAGE unset" "$artifact"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
