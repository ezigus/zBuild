#!/usr/bin/env bash
# tests/unit/judge-tools-test.sh — a judging call reads the code itself and can
# change nothing (#2464, ADR-072 §1, ADR-017 §11, ADR-067 §8).
#
# Why: on #1805 (runs 41643063636 and 41679237388) every judge but intake ran
# with every tool — editing, writing, running commands — and write access to
# the repository, yet made no tool call: its prompt said to judge what was
# pasted in, and what was pasted in was ten lines of the code it ruled on.
#
# T1 validate_manifest accepts config.router.tools: read
# T2 a call from a plugin declaring tools: read, or a call made with
#    ZBUILD_ROUTE_TOOLS=read, gets only Read, Grep and Glob and no MCP server;
#    tools: none still wins; a building call gets the full set
# T3 the shipped judges declare it: issue-acceptance, review-lens and
#    security-lens read; monitor and intake none; the building stages nothing
# T4 design's coverage check and test-author's assertion check ask for
#    read-only tools for their call, and only for it
# T5 the rules a judging call is given say it can open and search files and
#    change none; a building call's rules do not
# T6 the files a judging call opened are listed from its own step stream
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
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

_mk_plugin() {  # <name> <router-block-body> → plugin dir
    local dir="$TEST_TEMP_DIR/plugins/agent/$1"
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\n' "$1"
        printf 'hooks:\n  run: f_run\n'
        printf 'requires:\n  core:\n    - redaction\n'
        printf 'config:\n  router:\n%s' "$2"
    } > "$dir/manifest.yaml"
    printf '%s' "$dir"
}
_tools_of() {  # <argv> → the value after --tools, or "<absent>"
    awk 'p { print; f = 1; exit } $0 == "--tools" { p = 1 } END { if (!f) print "<absent>" }' <<< "$1"
}

print_test_section "T1: validate_manifest and tools: read"
_rd="$(_mk_plugin rd '    tools: read
')"
if validate_manifest "$_rd/manifest.yaml" >/dev/null 2>&1; then
    assert_pass "[T1] tools: read is accepted"
else
    assert_fail "[T1] tools: read is accepted" "$(validate_manifest "$_rd/manifest.yaml" 2>&1)"
fi

print_test_section "T2: the call's argv"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/argv"
echo OK
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_argv_for() {  # <plugin dir> [ZBUILD_ROUTE_TOOLS] → argv, one per line
    rm -f "$TEST_TEMP_DIR/argv"
    ZBUILD_ROUTE_TOOLS="${2:-}" ZBUILD_PLUGIN_DIR="$1" route_to_model T1 "ping" --skip-precondition >/dev/null 2>&1 || true
    cat "$TEST_TEMP_DIR/argv" 2>/dev/null
}
_plain="$(_mk_plugin plain '    max_turns: 3
')"
_none="$(_mk_plugin nonep '    tools: none
')"
_a_read="$(_argv_for "$_rd")"
_a_env="$(_argv_for "$_plain" read)"
_a_build="$(_argv_for "$_plain")"
_a_none="$(_argv_for "$_none" read)"
assert_eq "[T2] tools: read gets exactly Read, Grep and Glob" "Read,Grep,Glob" "$(_tools_of "$_a_read")"
assert_eq "[T2] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_a_read")"
assert_eq "[T2] a call made with ZBUILD_ROUTE_TOOLS=read gets the same" "Read,Grep,Glob" "$(_tools_of "$_a_env")"
assert_eq "[T2] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_a_env")"
assert_eq "[T2] a building call is not narrowed" "<absent>" "$(_tools_of "$_a_build")"
assert_eq "[T2] tools: none still gives no tools" "" "$(_tools_of "$_a_none")"

print_test_section "T3: the shipped judges declare it"
_knob() { manifest_router_knob "$REPO_ROOT/plugins/agent/$1/manifest.yaml" tools; }
assert_eq "[T3] issue-acceptance: read" "read" "$(_knob issue-acceptance)"
assert_eq "[T3] review-lens: read" "read" "$(_knob review-lens)"
assert_eq "[T3] security-lens: read" "read" "$(_knob security-lens)"
assert_eq "[T3] monitor: none" "none" "$(_knob monitor)"
assert_eq "[T3] intake: none" "none" "$(_knob intake)"
for _b in design test-author build; do
    assert_eq "[T3] $_b declares none of it: its building call has the full set" "" "$(_knob "$_b")"
done

print_test_section "T4: design's and test-author's checks ask for read-only tools"
_T4="$(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    route_to_model() { printf '%s' "${ZBUILD_ROUTE_TOOLS:-<unset>}" > "$TEST_TEMP_DIR/t4-design"; printf 'RQST-1: covered\nWORK-1: ok\n'; }
    D="$TEST_TEMP_DIR/t4-design.md"
    printf '# Design\n```acceptance\nWORK-1[code]: a flag is accepted covers: RQST-1\nTESTFILES:\nWORK-1: tests/a-test.sh\nWIRING: none\n```\n' > "$D"
    _design_coverage "$D" "- RQST-1: accept a flag" T2 >/dev/null 2>&1
    printf '%s' "${ZBUILD_ROUTE_TOOLS:-<unset>}"
)"
assert_eq "[T4] design's coverage check asks for read-only tools" "read" "$(cat "$TEST_TEMP_DIR/t4-design" 2>/dev/null)"
assert_eq "[T4] ...for its call only" "<unset>" "$_T4"
_T4b="$(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    route_to_model() { cat >/dev/null; printf '%s' "${ZBUILD_ROUTE_TOOLS:-<unset>}" > "$TEST_TEMP_DIR/t4-ta"; printf 'WORK-1: VERDICT: corresponds | REASON: fine\n'; }
    R="$TEST_TEMP_DIR/t4-repo"; mkdir -p "$R/tests"
    D="$TEST_TEMP_DIR/t4-ta.md"
    printf '# Design\n```acceptance\nWORK-1[code]: thing holds\nWIRING: none\nTESTFILES:\nWORK-1: tests/acc-test.sh\n```\n' > "$D"
    printf 'assert_eq "[WORK-1] thing holds" "1" "$got"\n' > "$R/tests/acc-test.sh"
    _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1
    printf '%s' "${ZBUILD_ROUTE_TOOLS:-<unset>}"
)"
assert_eq "[T4] test-author's assertion check asks for read-only tools" "read" "$(cat "$TEST_TEMP_DIR/t4-ta" 2>/dev/null)"
assert_eq "[T4] ...for its call only" "<unset>" "$_T4b"

print_test_section "T5: the rules a judging call is given"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
_r_fresh="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules plain "$S" "$_plain/manifest.yaml" fresh 2>/dev/null)")"
_r_full="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules plain "$S" "$_plain/manifest.yaml" 2>/dev/null)")"
_r_read="$(tr -s '[:space:]' ' ' <<< "$(_stage_block_rules rd "$S" "$_rd/manifest.yaml" fresh 2>/dev/null)")"
assert_contains "[T5] a judging call can open and search files" "$_r_fresh" "You can open and search files"
assert_contains "[T5] ...and change none" "$_r_fresh" "you cannot change, create or delete any file, or run anything"
assert_contains "[T5] a tools: read stage is told the same" "$_r_read" "You can open and search files"
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
_out="$(ZBUILD_ROUTE_TOOLS=read ZBUILD_ROUTER_OPENED_FILE="$_OPEN" ZBUILD_PLUGIN_DIR="$_plain" route_to_model T1 "ping" --skip-precondition 2>/dev/null)"
assert_eq "[T6] the call's answer is still its result" "OK" "$_out"
assert_contains "[T6] a file it read is listed" "$(cat "$_OPEN")" "/repo/scripts/a.sh"
assert_contains "[T6] ...and a file it searched" "$(cat "$_OPEN")" "/repo/scripts/b.sh"
assert_eq "[T6] ...and nothing else" "2" "$(grep -c . "$_OPEN")"

cleanup_test_env
print_test_results
