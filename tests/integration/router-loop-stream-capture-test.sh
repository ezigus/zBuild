#!/usr/bin/env bash
# tests/integration/router-loop-stream-capture-test.sh — a model call killed at
# its wall clock still leaves the record of what it did (#2139, #2252).
#
# Why: the router asked the CLI for one JSON envelope at the END of the call. A
# call killed at its wall clock printed nothing, so every timeout left a 0-byte
# raw output — #1844 run 36969128968 had 12 of them (build 6 × 900 s, design
# 3 × 600 s) and no way to tell what the model was doing.
#
# The stub behaves like the CLI: with `--output-format json` it prints only at
# the end; with `stream-json` it prints each step as it happens.
#
# S1 [change] a killed call's raw output holds the steps made before the kill
# S2 [change] the diagnostic event says how many turns ran and the last tool
# S3 [guard]  a call that finishes is read as before: its final result ends the
#             loop (LOOP_COMPLETE)
# S4 [change] the single-call path (route_to_model) keeps a killed call's steps
#             too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "router loop: a killed call keeps its record (#2139)"
setup_test_env "router-loop-stream-capture"
command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1 \
    || { echo "SKIP: no timeout binary"; cleanup_test_env; exit 0; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
export ZBUILD_RUN_ID="stream-capture-$$"
mkdir -p "$ZBUILD_ARTIFACT_DIR/stage-io"
mkdir -p "$HOME/.zbuild"; printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

# _stub <mode> — hang: three steps then hang; done: three steps then a result.
_stub() {
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
cat >/dev/null
stream=0; for a in "\$@"; do [[ "\$a" == stream-json ]] && stream=1; done
step() { [[ \$stream -eq 1 ]] && printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{}}]}}\n' "\$1"; }
step Read; step Edit; step Bash
if [[ "$1" == hang ]]; then sleep 30; exit 0; fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"done\\\\nLOOP_COMPLETE","num_turns":3,"usage":{"input_tokens":1,"output_tokens":1}}\n'
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}
cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
YAML
printf 'build prompt\n' > "$TEST_TEMP_DIR/prompt.txt"
_drive() {
    : > "$ZBUILD_EVENTS_JSONL"
    (
        source "$REPO_ROOT/core/event-bus/event-bus.sh"
        source "$REPO_ROOT/core/pipeline/template.sh"
        source "$REPO_ROOT/core/output/stage-io.sh"
        source "$REPO_ROOT/core/router/route.sh"
        export ZBUILD_SCOPE_OVERRIDE=1 ZBUILD_ROUTER_TIMEOUT=3 ZBUILD_ROUTER_RETRIES=0
        load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1
        export ZBUILD_CURRENT_STAGE=build
        route_to_model_loop T2 "$TEST_TEMP_DIR/prompt.txt" "$REPO" 1
    ) >/dev/null 2>&1
}

print_test_section "S1/S2: a killed call"
_stub hang; _drive
DIAG="$(jq -c 'select(.type=="router.loop.iter.error.diagnostic")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
RAW="$(jq -r '.data.raw_json_path // empty' <<< "$DIAG" 2>/dev/null)"
assert_contains "fixture: the call was killed at its wall clock" "$DIAG" '"rc":"124"'
assert_eq "[S1] the raw output holds the three steps made before the kill" "3" \
    "$(grep -c '"type":"assistant"' "$RAW" 2>/dev/null || echo 0)"
assert_eq "[S2] the diagnostic says 3 turns ran" "3" "$(jq -r '.data.num_turns // empty' <<< "$DIAG" 2>/dev/null)"
assert_eq "[S2] ...and names the last tool" "Bash" "$(jq -r '.data.last_tool // empty' <<< "$DIAG" 2>/dev/null)"

print_test_section "S3: a call that finishes"
_stub done; _drive
assert_contains "[S3] the final result still ends the loop" \
    "$(jq -c 'select(.type=="loop.complete")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "done_sentinel"

print_test_section "S4: the single-call path"
_stub hang; : > "$ZBUILD_EVENTS_JSONL"
(
    source "$REPO_ROOT/core/event-bus/event-bus.sh"
    source "$REPO_ROOT/core/pipeline/template.sh"
    source "$REPO_ROOT/core/output/stage-io.sh"
    source "$REPO_ROOT/core/router/route.sh"
    export ZBUILD_SCOPE_OVERRIDE=1 ZBUILD_ROUTER_TIMEOUT=3 ZBUILD_ROUTER_RETRIES=0
    load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1
    export ZBUILD_CURRENT_STAGE=build
    route_to_model T2 "judge this"
) >/dev/null 2>&1
assert_eq "[S4] the single-call raw output holds the three steps" "3" \
    "$(grep -c '"type":"assistant"' "$ZBUILD_ARTIFACT_DIR/stage-io/build-sync-error.raw-claude-output.json" 2>/dev/null || echo 0)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
