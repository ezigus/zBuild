#!/usr/bin/env bash
# tests/integration/cut-off-steps-test.sh — a model call cut off at its time
# limit leaves its next try the list of what it did (#2443, ADR-063).
#
# Why: on #1754 (run 41249802310) build's 3 tries were each cut off at 15
# minutes. Each read the same files again from scratch and wrote no notes, so
# the next try was given nothing of what the last one had found. The engine
# already keeps the call's steps as they happen (#2139); it now turns them into
# a short list the stage's next try reads, and keeps each try's record.
#
# C1 [change] a cut-off call leaves notes/<stage>.cut-off.md listing the steps
#             it made: what it read, what it ran, and what it said
# C2 [change] each try's raw record is its own file, named by round and try
# C3 [change] a call that is not cut off removes the list
# C4 [change] the single-call path (route_to_model) leaves the list too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a cut-off call's steps reach its next try (#2443)"
setup_test_env "cut-off-steps"
command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1 \
    || { echo "SKIP: no timeout binary"; cleanup_test_env; exit 0; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
export ZBUILD_RUN_ID="cut-off-steps-$$"
mkdir -p "$ZBUILD_ARTIFACT_DIR/stage-io"
mkdir -p "$HOME/.zbuild"; printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

# _stub <mode> — hang: three steps then hang past the limit; done: the same
# steps, then a result.
_stub() {
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the intake test first."},{"type":"tool_use","name":"Read","input":{"file_path":"/w/intake-result-test.sh"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash tests/unit/x-test.sh"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"The fake skips any path with intake-result in it."}]}}'
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
# _drive <loop|single> — one call as stage build, round 2, try 3.
_drive() {
    : > "$ZBUILD_EVENTS_JSONL"
    (
        source "$REPO_ROOT/core/event-bus/event-bus.sh"
        source "$REPO_ROOT/core/pipeline/template.sh"
        source "$REPO_ROOT/core/output/stage-io.sh"
        source "$REPO_ROOT/core/router/route.sh"
        export ZBUILD_SCOPE_OVERRIDE=1 ZBUILD_ROUTER_TIMEOUT=2
        load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1
        export ZBUILD_CURRENT_STAGE=build ZBUILD_CYCLE_ITER=2 ZBUILD_STAGE_TRY=3
        if [[ "$1" == loop ]]; then route_to_model_loop T2 "$TEST_TEMP_DIR/prompt.txt" "$REPO"
        else route_to_model T2 "judge this"; fi
    ) >/dev/null 2>&1
}
CUT="$ZBUILD_STATE_DIR/artifacts/notes/build.cut-off.md"

print_test_section "C1/C2: a call cut off at its limit"
_stub hang; _drive loop
_list="$(cat "$CUT" 2>/dev/null || true)"
assert_contains "[C1] the list names the file it read" "$_list" "/w/intake-result-test.sh"
assert_contains "[C1] ...the command it ran" "$_list" "bash tests/unit/x-test.sh"
assert_contains "[C1] ...and what it said" "$_list" "The fake skips any path with intake-result in it."
if [[ -s "$ZBUILD_ARTIFACT_DIR/stage-io/build-round2-try3-error.raw-claude-output.json" ]]; then
    assert_pass "[C2] the try's raw record is named by its round and try"
else
    assert_fail "[C2] the try's raw record is named by its round and try" \
        "$(ls "$ZBUILD_ARTIFACT_DIR/stage-io" 2>/dev/null | tr '\n' ' ')"
fi

print_test_section "C3: a call that is not cut off"
mkdir -p "${CUT%/*}"; printf 'from an earlier try\n' > "$CUT"
_stub done; _drive loop
if [[ -e "$CUT" ]]; then
    assert_fail "[C3] a call that finished removes the list" "$CUT is still there"
else
    assert_pass "[C3] a call that finished removes the list"
fi

print_test_section "C4: the single-call path"
_stub hang; _drive single
assert_contains "[C4] a cut-off single call leaves the list too" "$(cat "$CUT" 2>/dev/null || true)" "/w/intake-result-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
