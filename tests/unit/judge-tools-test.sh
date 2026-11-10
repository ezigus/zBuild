#!/usr/bin/env bash
# tests/unit/judge-tools-test.sh — a judging call reads the code itself and can
# change nothing (#2464, ADR-072 §1, ADR-017 §11, ADR-067 §8).
#
# Why: on #1805 (runs 41643063636 and 41679237388) every judge but intake ran
# with every tool — editing, writing, running commands — and write access to
# the repository, yet made no tool call: its prompt said to judge what was
# pasted in, and what was pasted in was ten lines of the code it ruled on.
#
# T1–T4 (the judges' tools, and the checks asking for them) moved to
#    tests/unit/call-tools-test.sh C1–C7 when every call came to list its tools
#    in its manifest (#2507, ADR-017 §12).
# T5 the rules a judging call is given say what it can do — open and search
#    files, read git, search the web, start a subagent — and that it changes
#    nothing; a building call's rules do not
# T6 the files a judging call opened are listed from its own step stream
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a judging call reads the code itself and changes nothing (#2464)"
setup_test_env "judge-tools"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch" "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"

_mk_plugin() {  # <name> <calls-block-body> → plugin dir
    local dir="$TEST_TEMP_DIR/plugins/agent/$1"
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\n' "$1"
        printf 'hooks:\n  run: f_run\n'
        printf 'requires:\n  core:\n    - redaction\n'
        printf 'calls:\n%s' "$2"
    } > "$dir/manifest.yaml"
    printf '%s' "$dir"
}
_plain="$(_mk_plugin plain '  main: [read-files, edit-files, run-commands, web-search, subagents, todo-list]
  check: [read-files, read-git, web-search, subagents]
')"
_rd="$(_mk_plugin rd '  main: [read-files, read-git, web-search, subagents]
')"

print_test_section "T5: the rules a judging call is given"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
_r_fresh="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules plain "$S" "$_plain/manifest.yaml" fresh 2>/dev/null)")"
_r_full="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules plain "$S" "$_plain/manifest.yaml" 2>/dev/null)")"
_r_read="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules rd "$S" "$_rd/manifest.yaml" fresh 2>/dev/null)")"
assert_contains "[T5] a judging call can open and search files" "$_r_fresh" "You can open and search files"
assert_contains "[T5] ...read git" "$_r_fresh" "run git diff, git log, git show and git status"
assert_contains "[T5] ...search the web and start a subagent" "$_r_fresh" "search the web and hand part of the work to a subagent"
assert_contains "[T5] ...and change none" "$_r_fresh" "you cannot change, create or delete any file, or run any other command"
assert_contains "[T5] a stage whose own call judges is told the same" "$_r_read" "You can open and search files"
if grep -q "You can open and search files" <<< "$_r_full"; then
    assert_fail "[T5] a building call is not told it can only read" "$_r_full"
else
    assert_pass "[T5] a building call is not told it can only read"
fi

print_test_section "T6: the files a judging call opened"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/scripts/a.sh"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x","path":"/repo/scripts/b.sh"}},{"type":"tool_use","name":"Glob","input":{"pattern":"*.sh"}}]}}'
printf '%s\n' '{"type":"result","subtype":"success","result":"OK","usage":{"input_tokens":1,"output_tokens":1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_OPEN="$TEST_TEMP_DIR/opened.txt"; : > "$_OPEN"
_out="$(ZBUILD_ROUTE_CALL=check ZBUILD_ROUTER_OPENED_FILE="$_OPEN" ZBUILD_PLUGIN_DIR="$_plain" route_to_model T1 "ping" --skip-precondition 2>/dev/null)"
assert_eq "[T6] the call's answer is still its result" "OK" "$_out"
assert_contains "[T6] a file it read is listed" "$(cat "$_OPEN")" "/repo/scripts/a.sh"
assert_contains "[T6] ...and a file it searched" "$(cat "$_OPEN")" "/repo/scripts/b.sh"
assert_eq "[T6] ...and nothing else" "2" "$(grep -c . "$_OPEN")"

cleanup_test_env
print_test_results
