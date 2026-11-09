#!/usr/bin/env bash
# tests/unit/call-tools-test.sh — every model call a stage makes is listed in
# its manifest by name, with its tools in zbuild's words; the provider module
# turns the words into its own (#2507, ADR-017 §12, ADR-003).
#
# Why: on #1805 run 42556446368 tools were chosen in two places — a stage's
# main call from its manifest, a check inside it in code (ZBUILD_ROUTE_TOOLS) —
# and most calls got every tool the provider ships, with every MCP server the
# machine has. The tool names were Claude's, so no other provider could run
# the manifests.
#
# C1 [change] a manifest's calls and their words are read; a call that lists
#             none has no tools; validate_manifest refuses an unknown word and
#             the retired config.router.tools
# C2 [change] the Anthropic module turns each word into its flags; it refuses
#             an unknown word and mcp, saying why; every call passes
#             --strict-mcp-config
# C3 [change] a single call gets its declared tools; a call named with
#             ZBUILD_ROUTE_CALL gets that call's; a call the manifest does not
#             list is refused before the model runs; a call outside any stage
#             gets no tools
# C4 [change] a loop call (build, test-author) gets its declared tools too
# C5 [change] a word the provider cannot supply refuses the run at start, with
#             the reason, in warn mode too
# C6 [change] the shipped stages declare: build, design, test-author main
#             calls the building set; every judge (issue-acceptance, the
#             lenses, design's and test-author's checks) the judging set;
#             intake and monitor none; no call is given mcp
# C8 [change] the call's tools are worked out even when the provider module was
#             not loaded by the model lookup (a test that stubs the lookup;
#             #2512 on Ubuntu: rc 2, no_tool_args)
# C7 [change] design's coverage check, test-author's assertion check and
#             intake's check name their call; the stage's own call is main
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every model call lists its tools in zbuild's words (#2507)"
setup_test_env "call-tools"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch" "$HOME/.zbuild" "$ZBUILD_REPO_ROOT"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
( cd "$ZBUILD_REPO_ROOT" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/router/providers/anthropic.sh
source "$REPO_ROOT/core/router/providers/anthropic.sh"

BUILDING="read-files edit-files run-commands web-search subagents todo-list"
JUDGING="read-files read-git web-search subagents"

_mk_plugin() {  # <name> <calls-block-body> [root] → plugin dir
    local dir="${3:-$TEST_TEMP_DIR/plugins}/agent/$1"
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\n' "$1"
        printf 'hooks:\n  run: f_run\n'
        printf 'requires:\n  core:\n    - redaction\n'
        printf 'config:\n  tier_default: T2\n'
        [[ -n "$2" ]] && printf 'calls:\n%s' "$2"
    } > "$dir/manifest.yaml"
    printf '%s' "$dir"
}
_valid() { validate_manifest "$1/manifest.yaml" >/dev/null 2>&1 && echo valid || echo refused; }
_after() {  # <flag> <argv> → the value after the flag, or "<absent>"
    awk -v f="$1" 'p { print; d = 1; exit } $0 == f { p = 1 } END { if (!d) print "<absent>" }' <<< "$2"
}

# ── C1 ───────────────────────────────────────────────────────────────────────
print_test_section "C1: a manifest's calls"
_two="$(_mk_plugin two '  main: [read-files, edit-files]
  check: []
')"
assert_eq "[C1] a manifest listing its calls is valid" "valid" "$(_valid "$_two")"
_w=""; manifest_call_words_v _w "$_two/manifest.yaml" main; _rc=$?
assert_eq "[C1] the main call's words are read" "0 read-files edit-files" "$_rc $_w"
_w="x"; manifest_call_words_v _w "$_two/manifest.yaml" check; _rc=$?
assert_eq "[C1] a call listing none is declared, with no words" "0 " "$_rc $_w"
manifest_call_words_v _w "$_two/manifest.yaml" other; _rc=$?
assert_eq "[C1] a call it does not list is not declared" "1" "$_rc"
assert_eq "[C1] an unknown word is refused" "refused" "$(_valid "$(_mk_plugin odd '  main: [read-files, all]
')")"
assert_eq "[C1] a call written without a list is refused" "refused" "$(_valid "$(_mk_plugin bare '  main: read-files
')")"
_old="$TEST_TEMP_DIR/plugins/agent/old"; mkdir -p "$_old"
printf 'id: old\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\nhooks:\n  run: f_run\nrequires:\n  core:\n    - redaction\nconfig:\n  router:\n    tools: read\n' > "$_old/manifest.yaml"
assert_eq "[C1] config.router.tools is retired: refused" "refused" "$(_valid "$_old")"

# ── C2 ───────────────────────────────────────────────────────────────────────
print_test_section "C2: the Anthropic module translates the words"
_targs() { provider_anthropic_tool_args "$@" 2>/dev/null; }
_one="$(_targs read-files)"
assert_eq "[C2] read-files → Read, Grep, Glob" "Read,Grep,Glob" "$(_after --tools "$_one")"
assert_eq "[C2] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_one")"
_all="$(_targs read-files edit-files run-commands web-search subagents todo-list)"
assert_eq "[C2] the building set" "Read,Grep,Glob,Edit,Write,Bash,WebSearch,WebFetch,Task,TodoWrite" "$(_after --tools "$_all")"
assert_eq "[C2] ...with no git-only rule: it runs commands" "<absent>" "$(_after --allowedTools "$_all")"
_git="$(_targs read-files read-git)"
assert_eq "[C2] read-git runs through Bash" "Read,Grep,Glob,Bash" "$(_after --tools "$_git")"
assert_eq "[C2] ...allowed only the read-only git commands" \
    "Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status *)" "$(_after --allowedTools "$_git")"
_none="$(_targs)"
assert_eq "[C2] no words → --tools with an empty value" "" "$(_after --tools "$_none")"
assert_eq "[C2] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_none")"
_why="$(provider_anthropic_tool_args read-files teleport 2>&1 >/dev/null)"; _rc=$?
[[ "$_rc" -ne 0 ]] && _rc=refused
assert_eq "[C2] an unknown word is refused" "refused" "$_rc"
assert_contains "[C2] ...naming the word" "$_why" "teleport"
_why="$(provider_anthropic_tool_args mcp 2>&1 >/dev/null)"; _rc=$?
[[ "$_rc" -ne 0 ]] && _rc=refused
assert_eq "[C2] mcp is refused: no call names its servers yet" "refused" "$_rc"
assert_contains "[C2] ...and says so" "$_why" "mcp"

# ── C3 ───────────────────────────────────────────────────────────────────────
print_test_section "C3: a single call"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/argv"
cat >/dev/null
jq -n '{type:"result", result:"done\nLOOP_COMPLETE", usage:{input_tokens:1, output_tokens:1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_argv_for() {  # <plugin dir|""> [call] → argv, one per line; "<not run>" when claude did not run
    rm -f "$TEST_TEMP_DIR/argv"
    if [[ -n "$1" ]]; then
        ZBUILD_ROUTE_CALL="${2:-}" ZBUILD_PLUGIN_DIR="$1" route_to_model T1 "ping" --skip-precondition >/dev/null 2>"$TEST_TEMP_DIR/err" || true
    else
        ( unset ZBUILD_PLUGIN_DIR; route_to_model T1 "ping" --skip-precondition ) >/dev/null 2>"$TEST_TEMP_DIR/err" || true
    fi
    cat "$TEST_TEMP_DIR/argv" 2>/dev/null || echo "<not run>"
}
_gj="$(_mk_plugin judge '  main: [read-files, read-git]
  check: [read-files]
')"
_a="$(_argv_for "$_gj")"
assert_eq "[C3] the main call gets its declared tools" "Read,Grep,Glob,Bash" "$(_after --tools "$_a")"
assert_eq "[C3] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_a")"
_a="$(_argv_for "$_gj" check)"
assert_eq "[C3] a call named check gets check's tools" "Read,Grep,Glob" "$(_after --tools "$_a")"
_a="$(_argv_for "$_gj" review)"
assert_eq "[C3] a call the manifest does not list is refused before the model runs" "<not run>" "$_a"
assert_contains "[C3] ...naming the call" "$(cat "$TEST_TEMP_DIR/err")" "review"
_rc=0; ZBUILD_ROUTE_CALL=review ZBUILD_PLUGIN_DIR="$_gj" route_to_model T1 "ping" --skip-precondition >/dev/null 2>&1 || _rc=$?
assert_eq "[C3] ...as a fatal error (rc 2)" "2" "$_rc"
_a="$(_argv_for "$(_mk_plugin nocalls '')")"
assert_eq "[C3] a stage whose manifest lists no calls cannot call a model" "<not run>" "$_a"
_a="$(_argv_for "")"
assert_eq "[C3] a call outside any stage has no tools" "" "$(_after --tools "$_a")"
assert_eq "[C3] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_a")"

# ── C4 ───────────────────────────────────────────────────────────────────────
print_test_section "C4: a loop call"
REPO="$ZBUILD_REPO_ROOT"
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
stage_prompt_compose_parts "$(printf '%s\ndo the thing\n%s\njudge it\n%s\nlimits\n' "$_ZB_SP_OWN" "$_ZB_SP_JUDGE" "$_ZB_SP_LIMITS")" > "$PROMPT_FILE"
_bl="$(_mk_plugin builder "  main: [${BUILDING// /, }]
")"
rm -f "$TEST_TEMP_DIR/argv"
( cd "$REPO" && ZBUILD_PLUGIN_DIR="$_bl" route_to_model_loop T2 "$PROMPT_FILE" "$REPO" ) >/dev/null 2>&1 || true
_a="$(cat "$TEST_TEMP_DIR/argv" 2>/dev/null)"
assert_eq "[C4] a loop call gets its declared tools" "Read,Grep,Glob,Edit,Write,Bash,WebSearch,WebFetch,Task,TodoWrite" "$(_after --tools "$_a")"
assert_eq "[C4] ...and no MCP server" "1" "$(grep -cx -- '--strict-mcp-config' <<< "$_a")"
rm -f "$TEST_TEMP_DIR/argv"
( cd "$REPO" && ZBUILD_ROUTE_CALL=other ZBUILD_PLUGIN_DIR="$_bl" route_to_model_loop T2 "$PROMPT_FILE" "$REPO" ) >/dev/null 2>&1 || true
assert_eq "[C4] a loop call the manifest does not list is refused" "<not run>" "$(cat "$TEST_TEMP_DIR/argv" 2>/dev/null || echo "<not run>")"

# ── C5 ───────────────────────────────────────────────────────────────────────
print_test_section "C5: a word the provider cannot supply refuses the run at start"
_C5="$(
    # shellcheck source=../../core/pipeline/runner.sh
    source "$REPO_ROOT/core/pipeline/runner.sh" >/dev/null 2>&1
    _pf() { ( unset ZBUILD_CONTRACT_VALIDATOR _TPL_SOURCE_FILE; _runner_validate_startup_preflight 2>&1; printf 'rc=%s' "$?" ); }
    printf 'CLEAN:%s\n' "$(_pf)"
    _mk_plugin mcpuser '  main: [read-files, mcp]
' "$ZBUILD_REPO_ROOT/.zbuild/plugins" >/dev/null
    printf 'MCP:%s\n' "$(_pf)"
)"
assert_contains "[C5] with every word supplied the run starts" "$(grep '^CLEAN:' <<< "$_C5")" "rc=0"
_c5m="$(sed -n '/^MCP:/,$p' <<< "$_C5")"
assert_contains "[C5] a repository stage asking for mcp refuses the run, in warn mode too" "$_c5m" "rc=1"
assert_contains "[C5] ...naming the stage's call" "$_c5m" "mcpuser"
assert_contains "[C5] ...and the word the provider cannot supply" "$_c5m" "mcp"

# ── C6 ───────────────────────────────────────────────────────────────────────
print_test_section "C6: what each shipped stage's calls get"
_words() { local _cw=""; manifest_call_words_v _cw "$REPO_ROOT/plugins/agent/$1/manifest.yaml" "$2" || _cw="<undeclared>"; printf '%s' "$_cw"; }
for _p in build design test-author; do
    assert_eq "[C6] $_p main: the building set" "$BUILDING" "$(_words "$_p" main)"
done
for _p in issue-acceptance review-lens security-lens; do
    assert_eq "[C6] $_p main: the judging set" "$JUDGING" "$(_words "$_p" main)"
done
assert_eq "[C6] design's coverage check: the judging set" "$JUDGING" "$(_words design coverage)"
assert_eq "[C6] test-author's assertion check: the judging set" "$JUDGING" "$(_words test-author check)"
assert_eq "[C6] intake main: none" "" "$(_words intake main)"
assert_eq "[C6] intake's check: none" "" "$(_words intake check)"
assert_eq "[C6] monitor main: none" "" "$(_words monitor main)"
_mcp=""
for _mf in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    [[ "$(<"$_mf")" =~ (^|$'\n')calls: ]] || continue
    _cl=""; manifest_calls_v _cl "$_mf"
    [[ " ${_cl//$'\n'/ } " == *" mcp "* ]] && _mcp+="$_mf "
done
assert_eq "[C6] no shipped call is given mcp" "" "$_mcp"

# ── C7 ───────────────────────────────────────────────────────────────────────
print_test_section "C7: each check names its call"
_C7="$(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    route_to_model() { printf '%s' "${ZBUILD_ROUTE_CALL:-main}" > "$TEST_TEMP_DIR/c7-design"; printf 'RQST-1: covered\nWORK-1: ok\n'; }
    D="$TEST_TEMP_DIR/c7-design.md"
    printf '# Design\n```acceptance\nWORK-1[code]: a flag is accepted covers: RQST-1\nTESTFILES:\nWORK-1: tests/a-test.sh\nWIRING: none\n```\n' > "$D"
    _design_coverage "$D" "- RQST-1: accept a flag" T2 >/dev/null 2>&1
    printf '%s' "${ZBUILD_ROUTE_CALL:-main}"
)"
assert_eq "[C7] design's coverage check is the call named coverage" "coverage" "$(cat "$TEST_TEMP_DIR/c7-design" 2>/dev/null)"
assert_eq "[C7] ...for its call only" "main" "$_C7"
_C7b="$(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    route_to_model() { cat >/dev/null; printf '%s' "${ZBUILD_ROUTE_CALL:-main}" > "$TEST_TEMP_DIR/c7-ta"; printf 'WORK-1: VERDICT: corresponds | REASON: fine\n'; }
    R="$TEST_TEMP_DIR/c7-repo"; mkdir -p "$R/tests"
    D="$TEST_TEMP_DIR/c7-ta.md"
    printf '# Design\n```acceptance\nWORK-1[code]: thing holds\nWIRING: none\nTESTFILES:\nWORK-1: tests/acc-test.sh\n```\n' > "$D"
    printf 'assert_eq "[WORK-1] thing holds" "1" "$got"\n' > "$R/tests/acc-test.sh"
    _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1
    printf '%s' "${ZBUILD_ROUTE_CALL:-main}"
)"
assert_eq "[C7] test-author's assertion check is the call named check" "check" "$(cat "$TEST_TEMP_DIR/c7-ta" 2>/dev/null)"
assert_eq "[C7] ...for its call only" "main" "$_C7b"
_C7c="$(
    # shellcheck source=../../plugins/agent/intake/plugin.sh
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
    route_to_model() {
        printf '%s\n' "${ZBUILD_ROUTE_CALL:-main}" >> "$TEST_TEMP_DIR/c7-intake"
        if [[ "${ZBUILD_ROUTE_CALL:-main}" == check ]]; then printf 'MISSING: none\n'
        else printf 'REQUIREMENT: RQFLAG-1 Accept a flag.\n'; fi
    }
    stage_prompt_compose_text() { printf '%s' "$2"; }
    _intake_requirements_json_v _l '{"title":"Flags","body":"Accept a flag."}' >/dev/null 2>&1
    printf '%s' "${ZBUILD_ROUTE_CALL:-main}"
)"
assert_eq "[C7] intake's first call is main, its second check" "main check" "$(tr '\n' ' ' < "$TEST_TEMP_DIR/c7-intake" 2>/dev/null | sed 's/ $//')"
assert_eq "[C7] ...for its call only" "main" "$_C7c"

print_test_section "C8: the provider module is loaded for the tools when the lookup did not"
# A fresh shell: nothing has loaded the provider module.
_C8="$(env -u ZBUILD_PLUGIN_DIR -u _ZBUILD_PROVIDER_ANTHROPIC_LOADED -u _ZBUILD_CALL_TOOLS_LOADED bash -c '
    source "$1/scripts/lib/helpers.sh"; source "$1/core/router/call-tools.sh"
    _ROUTE_PROVIDER=anthropic _route_call_tools_prepare >/dev/null 2>&1; printf "rc=%s" "$?"' _ "$REPO_ROOT")"
assert_eq "[C8] a call whose provider module is not yet loaded is prepared" "rc=0" "$_C8"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
