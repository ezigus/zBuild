#!/usr/bin/env bash
# tests/unit/intake-no-tools-test.sh — a stage whose calls have no tools is
# given none, and is not told to use one (#2448, ADR-017 §11, ADR-063, ADR-070 §1).
#
# Why: on #1805 (run 41352202870) intake's first call wrote its requirement
# list into its notes file — the engine's rules tell every stage to — and that
# tool call used its one turn: stop_reason tool_use, num_turns 2, reported as
# out_of_turns, and the retry cost another call.
#
# T1 [change] a call its manifest lists with no tools (`main: []`, #2507,
#             ADR-017 §12 — it replaced config.router.tools: none) is valid
# T2 [change] such a call passes --strict-mcp-config --tools "" to claude; a
#             call with tools gets them, and no MCP server either
# T3 [change] the rules block of such a stage names no notes file; another
#             stage's still does
# T4 [change] intake's two calls list no tools, and it has max_turns: 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a stage with no tools gets none, and is not told to use one (#2448)"
setup_test_env "intake-no-tools"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch" "$HOME/.zbuild"
# The operator override token, so --skip-precondition is honoured.
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
        printf 'config:\n  router:\n    max_turns: 1\n'
        printf 'calls:\n%s' "$2"
    } > "$dir/manifest.yaml"
    printf '%s' "$dir"
}

print_test_section "T1: a call with no tools"
_ok="$(_mk_plugin ok '  main: []
')"
if validate_manifest "$_ok/manifest.yaml" >/dev/null 2>&1; then
    assert_pass "[T1] main: [] is accepted"
else
    assert_fail "[T1] main: [] is accepted" "$(validate_manifest "$_ok/manifest.yaml" 2>&1)"
fi

print_test_section "T2: the call's argv"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/argv"
echo OK
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_argv_for() {  # <plugin dir> → argv, one per line
    rm -f "$TEST_TEMP_DIR/argv"
    ZBUILD_PLUGIN_DIR="$1" route_to_model T1 "ping" --skip-precondition >/dev/null 2>&1 || true
    cat "$TEST_TEMP_DIR/argv" 2>/dev/null
}
_none="$(_argv_for "$_ok")"
_dflt="$(_argv_for "$(_mk_plugin dflt '  main: [read-files, edit-files]
')")"
assert_contains "[T2] the call reached claude" "$_dflt" "--print"
if grep -qx -- '--strict-mcp-config' <<< "$_none"; then
    assert_pass "[T2] a call with no tools passes --strict-mcp-config"
else
    assert_fail "[T2] a call with no tools passes --strict-mcp-config" "argv: $_none"
fi
assert_eq "[T2] ...and --tools with an empty value" "1" \
    "$(awk 'p { print ($0 == "" ? 1 : 0); exit } $0 == "--tools" { p = 1 }' <<< "$_none")"
assert_eq "[T2] a call with tools gets them" "Read,Grep,Glob,Edit,Write" \
    "$(awk 'p { print; exit } $0 == "--tools" { p = 1 }' <<< "$_dflt")"
assert_eq "[T2] ...and no MCP server either" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_dflt")"

print_test_section "T3: the rules block"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
_r_none="$(_stage_block_rules ok "$S" "$_ok/manifest.yaml" 2>/dev/null)"
_r_dflt="$(_stage_block_rules dflt "$S" "$TEST_TEMP_DIR/plugins/agent/dflt/manifest.yaml" 2>/dev/null)"
if grep -qi "notes file" <<< "$_r_none"; then
    assert_fail "[T3] a stage with no tools is not told to write a notes file" "$_r_none"
else
    assert_pass "[T3] a stage with no tools is not told to write a notes file"
fi
assert_contains "[T3] another stage is still told its notes file" "$_r_dflt" "$(stage_notes_path "$S" dflt)"

print_test_section "T4: intake declares it"
_im="$REPO_ROOT/plugins/agent/intake/manifest.yaml"
_iw="x"; manifest_call_words_v _iw "$_im" main
assert_eq "[T4] intake's main call: no tools" "" "$_iw"
_iw="x"; manifest_call_words_v _iw "$_im" check
assert_eq "[T4] intake's check: no tools" "" "$_iw"
assert_eq "[T4] intake: max_turns 1" "1" "$(manifest_router_knob "$_im" max_turns)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
