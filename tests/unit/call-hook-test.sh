#!/usr/bin/env bash
# tests/unit/call-hook-test.sh — the guards in a call's PreToolUse hook: git
# that only reads, subagents on the call's model, no private path or secret in
# a web search, and test-author reading the existing code in the copy from
# before the change (#2507, ADR-017 §12, ADR-003, ADR-004, ADR-072 §2).
#
# Why: on #1805 run 42556446368 a haiku call started a sonnet subagent, going
# around the models in config/models.json; and test-author, told not to read the
# code, built a fake plugin without the role the engine requires. A judge given
# read-git runs it through the shell, so the shell must run nothing else.
#
# G1 [change] a call's settings hold the hook with the guards its tools need:
#             a judge's git is read-only, a call that searches the web is told
#             no private paths (it checks only for secrets), test-author's main
#             call names the copy of the code; a call with no tools and a short
#             limit gets no hook
# G2 [change] read-git: git diff, log, show and status pass; --output, anything
#             chained after them, and any other command are refused, saying why
# G3 [change] a subagent request that names a model is refused; one that does
#             not passes
# G4 [change] a search or fetch holding text that looks like a secret is
#             refused, and the model is told why; one that only names a private
#             file is not (prompt redaction stays separate), nor an ordinary one
# G5 [change] test-author's read of a working-copy file outside the test
#             folders is refused, naming the copy — whatever its name; a file in
#             the test folders and the copy stay readable
# G6 [change] with no deadline the hook never says time is up
# G7 [change] test-author's prompt says where the code from before the change
#             is, and its main call is the one the read guard is for# G8 [change] a refusal is valid JSON whatever the command holds (a tab, a
#             carriage return); a web guard that cannot read what a secret looks
#             like refuses, never allows (review on #2512)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "guards in a call's hook: git, subagents, web, test-author's reads (#2507)"
setup_test_env "call-hook"

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
R="$ZBUILD_REPO_ROOT"
BASE="$TEST_TEMP_DIR/state/base-code"
HOOK="$REPO_ROOT/core/router/tool-hook.sh"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

_mk_plugin() {  # <name> <calls-block-body> → plugin dir
    local dir="$TEST_TEMP_DIR/plugins/agent/$1"
    mkdir -p "$dir"
    printf 'id: %s\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\nhooks:\n  run: f_run\nrequires:\n  core:\n    - redaction\nconfig:\n  tier_default: T2\ncalls:\n%s' \
        "$1" "$2" > "$dir/manifest.yaml"
    printf '%s' "$dir"
}
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
cat >/dev/null
s=""; p=""
for a in "\$@"; do [[ "\$p" == --settings ]] && s="\$a"; p="\$a"; done
cp "\$s" "$TEST_TEMP_DIR/settings.json" 2>/dev/null
jq -n '{type:"result", result:"OK", usage:{input_tokens:1, output_tokens:1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
_hook_of() {  # <plugin dir> [timeout] [base-code dir] → the hook's command, or "<none>"
    rm -f "$TEST_TEMP_DIR/settings.json"
    ZBUILD_ROUTER_TIMEOUT="${2:-600}" ZBUILD_ROUTE_BASE_CODE="${3:-}" ZBUILD_PLUGIN_DIR="$1" \
        route_to_model T1 "ping" --skip-precondition >/dev/null 2>&1 || true
    jq -r '.hooks.PreToolUse[0].hooks[0].command // "<none>"' "$TEST_TEMP_DIR/settings.json" 2>/dev/null || echo "<no call>"
}

# ── G1 ───────────────────────────────────────────────────────────────────────
print_test_section "G1: the guards a call's tools need"
_judge="$(_mk_plugin judge '  main: [read-files, read-git, web-search, subagents]
')"
_build="$(_mk_plugin build '  main: [read-files, edit-files, run-commands, web-search, subagents, todo-list]
')"
_quiet="$(_mk_plugin quiet '  main: []
')"
_hj="$(_hook_of "$_judge")"
assert_contains "[G1] the hook is the router's tool hook" "$_hj" "core/router/tool-hook.sh"
assert_contains "[G1] a judge's git is read-only" "$_hj" "--git-only"
if [[ "$_hj" == *--private* ]]; then assert_fail "[G1] a call that searches the web is not given the private paths" "$_hj"
else assert_pass "[G1] a call that searches the web is not given the private paths"; fi
_hb="$(_hook_of "$_build")"
if [[ "$_hb" == *--git-only* ]]; then assert_fail "[G1] a call that runs commands is not limited to git" "$_hb"
else assert_pass "[G1] a call that runs commands is not limited to git"; fi
if [[ "$_hb" == *--code-copy* ]]; then assert_fail "[G1] only a call given the copy has the read guard" "$_hb"
else assert_pass "[G1] only a call given the copy has the read guard"; fi
_ht="$(_hook_of "$_build" 600 "$BASE")"
assert_contains "[G1] a call given the copy of the code has the read guard" "$_ht" "--code-copy"
assert_contains "[G1] ...naming the copy" "$_ht" "$BASE"
assert_contains "[G1] ...and the test folders" "$_ht" "--test-glob"
assert_eq "[G1] a short call with no tools gets no hook" "<none>" "$(_hook_of "$_quiet" 60)"
_hs="$(_hook_of "$_judge" 60)"
assert_contains "[G1] a short call with tools still gets its guards" "$_hs" "--git-only"

_ask() {  # <tool> <input-json> [hook args...] → the hook's answer
    local t="$1" i="$2"; shift 2
    jq -cn --arg t "$t" --argjson i "$i" '{tool_name:$t, tool_input:$i}' | bash "$HOOK" "$@"
}
_dec() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "${1:-{\}}" 2>/dev/null || echo allow; }
_why() { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${1:-{\}}" 2>/dev/null; }
_cmd() { jq -cn --arg c "$1" '{command:$c}'; }

# ── G2 ───────────────────────────────────────────────────────────────────────
print_test_section "G2: read-git runs only git diff, log, show and status"
for _c in 'git diff abc123 HEAD -- core/a.sh' 'git log --oneline -5' 'git show abc123:core/a.sh' \
          'git status --short' "git -C $R diff abc123 HEAD" 'git --no-pager log -p abc123..HEAD'; do
    assert_eq "[G2] allowed: $_c" "allow" "$(_dec "$(_ask Bash "$(_cmd "$_c")" --git-only 0 '')")"
done
for _c in 'git diff --output=/tmp/x abc123' 'git diff --output /tmp/x' 'git diff | head' 'git log; rm -rf x' \
          'git status && ls' 'git status || ls' 'git show $(id)' 'git show `id`' 'git diff > out.txt' \
          'ls' 'cat core/a.sh' 'git push origin main' 'git checkout -- core/a.sh' $'git status\nrm x'; do
    assert_eq "[G2] refused: ${_c//$'\n'/\\n}" "deny" "$(_dec "$(_ask Bash "$(_cmd "$_c")" --git-only 0 '')")"
done
_w="$(_why "$(_ask Bash "$(_cmd 'ls')" --git-only 0 '')")"
assert_contains "[G2] ...told what it may run" "$_w" "git diff, git log, git show and git status"
assert_eq "[G2] without --git-only any command passes" "allow" "$(_dec "$(_ask Bash "$(_cmd 'ls | head')" 0 '')")"

# ── G3 ───────────────────────────────────────────────────────────────────────
print_test_section "G3: a subagent runs on the call's model"
for _t in Agent Task; do
    _o="$(_ask "$_t" '{"description":"look","prompt":"read it","model":"opus"}' 0 '')"
    assert_eq "[G3] $_t naming a model is refused" "deny" "$(_dec "$_o")"
    assert_contains "[G3] ...told it runs on this call's model" "$(_why "$_o")" "this call's model"
    assert_eq "[G3] $_t naming none passes" "allow" "$(_dec "$(_ask "$_t" '{"description":"look","prompt":"read it"}' 0 '')")"
done

# ── G4 ───────────────────────────────────────────────────────────────────────
print_test_section "G4: no secret leaves in a search"
_hook_ask() {  # <hook command> <tool> <input-json> → the answer of the hook as the router wires it
    jq -cn --arg t "$2" --argjson i "$3" '{tool_name:$t, tool_input:$i}' | eval "$1"
}
_o="$(_hook_ask "$_hj" WebSearch '{"query":"how to parse .env files"}')"
assert_eq "[G4] a query that only names a private file is allowed" "allow" "$(_dec "$_o")"
_o="$(_hook_ask "$_hj" WebFetch '{"url":"https://example.com/key.pem","prompt":"x"}')"
assert_eq "[G4] ...and so is an address that does" "allow" "$(_dec "$_o")"
_o="$(_hook_ask "$_hj" WebSearch '{"query":"AKIAABCDEFGHIJKLMNOP leaked"}')"
assert_eq "[G4] a query holding a secret is refused, as the router wires the hook" "deny" "$(_dec "$_o")"
_o="$(_ask WebSearch '{"query":"AKIAABCDEFGHIJKLMNOP leaked"}' 0 '')"
assert_eq "[G4] a query holding a secret is refused" "deny" "$(_dec "$_o")"
assert_contains "[G4] ...told why" "$(_why "$_o")" "secret"
_o="$(_ask WebSearch '{"query":"api_key=sk_live_abcdefghijkl"}' 0 '')"
assert_eq "[G4] ...a credential assignment too" "deny" "$(_dec "$_o")"
_o="$(_ask WebFetch '{"url":"https://example.com/?token=abcdefghijklmnop","prompt":"x"}' 0 '')"
assert_eq "[G4] ...and an address carrying one" "deny" "$(_dec "$_o")"
assert_eq "[G4] an ordinary search passes" "allow" "$(_dec "$(_ask WebSearch '{"query":"bash nameref local scope"}' 0 '')")"
assert_eq "[G4] an ordinary fetch passes" "allow" "$(_dec "$(_ask WebFetch '{"url":"https://www.gnu.org/software/bash/manual/","prompt":"x"}' 0 '')")"

# ── G5 ───────────────────────────────────────────────────────────────────────
print_test_section "G5: test-author reads the existing code in the copy"
_RG=(--repo "$R" --code-copy "$BASE" --test-glob 'tests/*' --test-glob 'plugins/*/*/tests/*')
_rd() { jq -cn --arg f "$1" '{file_path:$f}'; }
_o="$(_ask Read "$(_rd "$R/core/router/route.sh")" "${_RG[@]}" 0 '')"
assert_eq "[G5] reading a working-copy code file is refused" "deny" "$(_dec "$_o")"
assert_contains "[G5] ...told to read it in the copy" "$(_why "$_o")" "$BASE/core/router/route.sh"
assert_eq "[G5] ...a relative path is the working copy's" "deny" "$(_dec "$(_ask Read "$(_rd core/router/route.sh)" "${_RG[@]}" 0 '')")"
assert_eq "[G5] a test file stays readable" "allow" "$(_dec "$(_ask Read "$(_rd "$R/tests/unit/a-test.sh")" "${_RG[@]}" 0 '')")"
assert_eq "[G5] ...and a plugin's own tests" "allow" "$(_dec "$(_ask Read "$(_rd "$R/plugins/agent/x/tests/b-test.sh")" "${_RG[@]}" 0 '')")"
assert_eq "[G5] a file named like a test outside the test folders is refused" "deny" "$(_dec "$(_ask Read "$(_rd "$R/scripts/lib/test-output-sanitize.sh")" "${_RG[@]}" 0 '')")"
assert_eq "[G5] the copy stays readable" "allow" "$(_dec "$(_ask Read "$(_rd "$BASE/core/router/route.sh")" "${_RG[@]}" 0 '')")"
assert_eq "[G5] a file outside the working copy stays readable" "allow" "$(_dec "$(_ask Read "$(_rd "$TEST_TEMP_DIR/state/notes.md")" "${_RG[@]}" 0 '')")"
assert_eq "[G5] searching working-copy code is refused" "deny" \
    "$(_dec "$(_ask Grep "$(jq -cn --arg p "$R/core" '{pattern:"role", path:$p}')" "${_RG[@]}" 0 '')")"
assert_eq "[G5] ...and a search with no folder: it is the working copy" "deny" "$(_dec "$(_ask Grep '{"pattern":"role"}' "${_RG[@]}" 0 '')")"
assert_eq "[G5] searching the copy passes" "allow" \
    "$(_dec "$(_ask Grep "$(jq -cn --arg p "$BASE/core" '{pattern:"role", path:$p}')" "${_RG[@]}" 0 '')")"
assert_eq "[G5] searching the tests passes" "allow" \
    "$(_dec "$(_ask Grep "$(jq -cn --arg p "$R/tests" '{pattern:"role", path:$p}')" "${_RG[@]}" 0 '')")"
assert_eq "[G5] listing files by name passes" "allow" "$(_dec "$(_ask Glob '{"pattern":"**/*.sh"}' "${_RG[@]}" 0 '')")"
assert_eq "[G5] without the guard a code file is readable" "allow" "$(_dec "$(_ask Read "$(_rd "$R/core/router/route.sh")" 0 '')")"

# ── G6 ───────────────────────────────────────────────────────────────────────
print_test_section "G6: no deadline, no time-up"
assert_eq "[G6] deadline 0: a tool is allowed" "allow" "$(_dec "$(_ask Read "$(_rd "$R/a.sh")" 0 '')")"
printf -v _now '%(%s)T' -1
assert_eq "[G6] a passed deadline still refuses every tool" "deny" "$(_dec "$(_ask Read "$(_rd "$R/tests/a-test.sh")" "${_RG[@]}" $(( _now - 1 )) '')")"

# ── G7 ───────────────────────────────────────────────────────────────────────
print_test_section "G7: test-author is pointed at the copy"
_G7="$(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    judge_base_dir_v() { local -n _b="$1"; _b="$BASE"; }
    stage_prompt_compose_parts() { printf '%s' "${@: -1}"; }
    route_to_model_loop() {
        cp "$2" "$TEST_TEMP_DIR/g7-prompt" 2>/dev/null
        printf '%s' "${ZBUILD_ROUTE_CALL:-main}|${ZBUILD_ROUTE_BASE_CODE:-}" > "$TEST_TEMP_DIR/g7-env"
        _ROUTE_LOOP_TERMINATED_REASON=no_done_sentinel; return 1
    }
    A="$TEST_TEMP_DIR/g7/artifacts"; mkdir -p "$A" "$R/tests"
    printf '# Design\n```acceptance\nWORK-1[code]: thing holds\nWIRING: core/x.sh\nTESTFILES:\nWORK-1: tests/acc-test.sh\n```\n' > "$A/design.md"
    export ZBUILD_ARTIFACT_DIR="$A"
    test_author_run test-author "$TEST_TEMP_DIR/g7/pipeline-state.json" >/dev/null 2>&1
    printf '%s' "${ZBUILD_ROUTE_BASE_CODE:-<unset>}"
)"
_p="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/g7-prompt" 2>/dev/null)"
assert_contains "[G7] the prompt has the block for the code from before the change" "$_p" "The code from before this change"
assert_contains "[G7] ...naming the copy" "$_p" "$BASE"
assert_contains "[G7] ...and says to read the existing code there" "$_p" "read the existing code there"
assert_eq "[G7] its main call is given the copy for the read guard" "main|$BASE" "$(cat "$TEST_TEMP_DIR/g7-env" 2>/dev/null)"
assert_eq "[G7] ...for that call only" "<unset>" "$_G7"

print_test_section "G8: a refusal is valid JSON; the web guard fails closed"
_g8="$(_ask Bash "$(_cmd $'git push\torigin\r main')" --git-only 0 '')"
assert_eq "[G8] a refusal of a command holding a tab and a CR is valid JSON" "deny" \
    "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$_g8" 2>/dev/null || echo invalid)"
_G8D="$TEST_TEMP_DIR/g8/core/router"; mkdir -p "$_G8D"; cp "$HOOK" "$_G8D/tool-hook.sh"
_g8w="$(jq -cn '{tool_name:"WebSearch", tool_input:{query:"bash nameref"}}' | bash "$_G8D/tool-hook.sh" 0 '')"
assert_eq "[G8] a web search with no secret definitions to check against is refused" "deny" "$(_dec "$_g8w")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
