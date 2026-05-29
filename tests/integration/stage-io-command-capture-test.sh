#!/usr/bin/env bash
# Tests: end-to-end command-kind stage-io capture for adopted call sites
# (ADR-015 v2, issue #439). Exercises intake (`gh issue view`) and build
# (`git apply --check`) — the two adoption sites for #439.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io command-kind capture — intake + build adoption (ADR-015 v2, #439)"
setup_test_env "stage-io-command-int"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="run-stage-io-cmd"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# ─── Load template machinery + mock destinations ─────────────────────────────
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

TPL="$TEST_TEMP_DIR/cmd-io-template.yaml"
cat > "$TPL" <<'EOF'
id: cmd-io-int
name: Command IO Integration
defaults:
  strategy: fanout

stages:
  - id: intake
    gate: auto
    roles: [intake]
    io:
      destinations: [file]
  - id: build
    gate: auto
    roles: [build]
    io:
      destinations: [file]
EOF
load_template "$TPL"

# ─── Mock gh in $TEST_TEMP_DIR/bin so intake's run_captured_command captures it
cat > "$TEST_TEMP_DIR/bin/gh" <<'GHSHIM'
#!/usr/bin/env bash
# Mock: gh issue view <N> --json title,body --jq <filter>
# Produces title+body for jq's default filter to assemble.
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    # Find --jq filter
    filter=""
    for ((i=1;i<=$#;i++)); do
        if [[ "${!i}" == "--jq" ]]; then
            j=$((i+1))
            filter="${!j}"
        fi
    done
    payload='{"title":"Test Issue Title","body":"Test issue body line."}'
    if [[ -n "$filter" ]]; then
        printf '%s' "$payload" | jq -r "$filter"
    else
        printf '%s' "$payload"
    fi
    exit 0
fi
exit 0
GHSHIM
chmod +x "$TEST_TEMP_DIR/bin/gh"

# ─── Source intake plugin ─────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"
intake_init >/dev/null 2>&1 || true

STATE_DIR="$TEST_TEMP_DIR/intake-state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"439","stage_statuses":{}}' > "$STATE_FILE"

unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="439"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
intake_rc=$?
set -e

assert_eq "intake_run with mocked gh returns rc=0" "0" "$intake_rc"
assert_file_exists "intake.md created" "$STATE_DIR/intake.md"
intake_md="$(cat "$STATE_DIR/intake.md")"
assert_contains "intake.md contains mocked title" "$intake_md" "Test Issue Title"
assert_contains "intake.md contains mocked body" "$intake_md" "Test issue body line."

artifact_intake="$ZBUILD_STATE_DIR/artifacts/stage-io/intake-1.json"
assert_file_exists "intake stage-io artifact written" "$artifact_intake"
json_intake="$(cat "$artifact_intake" 2>/dev/null || echo '{}')"
assert_json_key "intake artifact kind == command" "$json_intake" ".kind" "command"
assert_json_key "intake artifact stage == intake" "$json_intake" ".stage" "intake"
intake_input="$(printf '%s' "$json_intake" | jq -r .input)"
assert_contains "intake artifact .input starts with gh issue view" "$intake_input" "gh issue view"

# ─── Build adoption removed by #467 (ADR-018 Pattern 2) ──────────────────────
# Pre-#467 the build plugin invoked `git -C <repo> apply --check` on an LLM-
# emitted patch and that call was wrapped by `run_captured_command` to produce
# a build-*.json command-kind artifact under state/artifacts/stage-io. With
# Pattern 2 the build plugin derives diff.patch from the working tree (via
# `git diff HEAD` in route_to_model_loop) and no longer runs `git apply --check`
# inside the plugin — the test stage owns patch validation now. Intake is the
# remaining command-kind adoption site exercised by this test.

cleanup_test_env
print_test_results
exit $((FAIL > 0))
