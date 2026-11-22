#!/usr/bin/env bash
# tests/unit/read-github-tool-test.sh — read-github: a judge looks GitHub up,
# read-only, through one fixed wrapper (#2584 R6; ADR-017 §12, amended
# 2026-11-22).
#
# Why: on #1764 the engine claimed issues with a `zbuild:claimed` label that did
# not exist; the lenses read files and git only, so none could see it. The
# judging stages get a lookup of the outside world that writes nothing. Review
# of the first build: a guard that read gh's own command line let grouped and
# quoted flags through (`gh api -iXPOST …`, `"-f"`, `\-f`), and gh built POST
# and DELETE from them. The model now never builds a gh command line: it runs
# `zbuild-gh-get <endpoint> [jq-filter]`, and the wrapper builds gh's argv itself
# (tests/unit/gh-get-wrapper-test.sh).
#
# RG1 [change] read-github is one of zbuild's words: a manifest naming it is valid
# RG2 [change] the Anthropic module gives it the shell, allowed only the wrapper;
#              with read-git it is one shell, allowed both
# RG3 [change] a call with read-github (and no run-commands) gets the hook's
#              --gh-read guard and its secret folder; its shim runs the wrapper;
#              a call that runs commands gets neither
# RG4 [change] the guard lets through the wrapper with an endpoint and a jq
#              filter, quoted or not: `&` in a quoted query and `|` in a quoted
#              filter are data
# RG5 [change] it refuses every gh command line — the six bypasses of the review
#              and their separated forms — and any wrapper command with
#              anything chained, expanded or redirected, or a third word
# RG6 [change] with --gh-read alone git is refused; with --git-only too, both run;
#              git's --no-index (which reads any file) is refused; with a secret
#              folder, no git command names it, an ancestor, a path through ..,
#              ~, $ or a glob in a full path — git's reading of the repo still runs
# RG7 [change] who gets it: issue-acceptance's call and both of the lens's calls;
#              no building call
# RG8 [change] a judge with it is told the wrapper's form
# RG9 [change] the model's call has no GitHub token in its environment: the
#              shim's folder leads its PATH, the token is in a file only the
#              wrapper reads, and the hook refuses reading that file or
#              searching a folder that holds it (git's reach to it: RG6)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "read-github: a judge looks GitHub up, read-only (#2584)"
setup_test_env "read-github-tool"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_REPO_ROOT"

# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../core/router/call-tools.sh
source "$REPO_ROOT/core/router/call-tools.sh"
# shellcheck source=../../core/router/providers/anthropic.sh
source "$REPO_ROOT/core/router/providers/anthropic.sh"
# shellcheck source=../../scripts/lib/stage-limits.sh
source "$REPO_ROOT/scripts/lib/stage-limits.sh"
HOOK="$REPO_ROOT/core/router/tool-hook.sh"

_mk_plugin() {  # <name> <calls-block-body> → plugin dir
    local dir="$TEST_TEMP_DIR/plugins/agent/$1"; mkdir -p "$dir"
    printf 'id: %s\nname: Fixture\nkind: agent\nversion: 0.0.1\nsummary: fixture\nhooks:\n  run: f_run\nrequires:\n  core:\n    - redaction\nconfig:\n  tier_default: T2\ncalls:\n%s' \
        "$1" "$2" > "$dir/manifest.yaml"
    printf '%s' "$dir"
}
_after() { awk -v f="$1" 'p { print; d = 1; exit } $0 == f { p = 1 } END { if (!d) print "<absent>" }' <<< "$2"; }
_ask() { jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK" "${@:2}" 0 ''; }
_dec() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "${1:-{\}}" 2>/dev/null || echo allow; }
_why() { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${1:-{\}}" 2>/dev/null; }

print_test_section "RG1: the word"
_lk="$(_mk_plugin lookup '  main: [read-files, read-github]
')"
assert_eq "[RG1] a manifest naming read-github is valid" "valid" \
    "$(validate_manifest "$_lk/manifest.yaml" >/dev/null 2>&1 && echo valid || echo refused)"

print_test_section "RG2: the provider"
_a="$(provider_anthropic_tool_args read-files read-github 2>/dev/null)"
assert_eq "[RG2] read-github runs through the shell" "Read,Grep,Glob,Bash" "$(_after --tools "$_a")"
assert_eq "[RG2] ...allowed only the wrapper" "Bash(zbuild-gh-get *)" "$(_after --allowedTools "$_a")"
_a="$(provider_anthropic_tool_args read-files read-git read-github 2>/dev/null)"
assert_eq "[RG2] with read-git: one shell" "Read,Grep,Glob,Bash" "$(_after --tools "$_a")"
assert_contains "[RG2] ...allowed git's readers" "$(_after --allowedTools "$_a")" "Bash(git diff *)"
assert_contains "[RG2] ...and the wrapper" "$(_after --allowedTools "$_a")" "Bash(zbuild-gh-get *)"

print_test_section "RG3: the hook's guard"
_flags() { _ROUTE_TOOLS_KEY="" ZBUILD_PLUGIN_DIR="$1" _route_call_tools_prepare >/dev/null 2>&1; printf '%s' "${_ROUTE_HOOK_FLAGS[*]:-}"; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"; mkdir -p "$ZBUILD_STAGE_SCRATCH"
export GH_TOKEN="ghs_testtoken0123456789"
_f="$(_flags "$_lk")"
assert_contains "[RG3] a call with read-github is guarded" " $_f " " --gh-read "
assert_contains "[RG3] ...with its secret folder" " $_f " " --secret-dir "
_ROUTE_TOOLS_KEY="" ZBUILD_PLUGIN_DIR="$_lk" _route_call_tools_prepare >/dev/null 2>&1
_bin="${_ROUTE_GH_BIN:-<none>}"
assert_eq "[RG3] its shim is the wrapper's one name" "yes" "$([[ -x "$_bin/zbuild-gh-get" ]] && echo yes || echo no)"
assert_eq "[RG3] ...the engine's own folder" "$REPO_ROOT/core/router/gh-bin" "$_bin"
assert_contains "[RG3] ...which runs the engine's wrapper" "$(cat "$_bin/zbuild-gh-get" 2>/dev/null)" "gh-get.sh"
_bd="$(_mk_plugin builder '  main: [read-files, edit-files, run-commands, read-github]
')"
_f="$(_flags "$_bd")"
_lacks "[RG3] a call that runs commands is not guarded" " $_f " " --gh-read "
_ROUTE_TOOLS_KEY="" ZBUILD_PLUGIN_DIR="$_bd" _route_call_tools_prepare >/dev/null 2>&1
assert_eq "[RG3] ...and has no shim" "" "${_ROUTE_GH_BIN:-}"
_ROUTE_TOOLS_KEY="" ZBUILD_PLUGIN_DIR="$_lk" _route_call_tools_prepare >/dev/null 2>&1
SECRET_DIR="${_ROUTE_GH_SECRET_DIR:-$TEST_TEMP_DIR/no-secret-dir}"

print_test_section "RG4: the wrapper runs"
for _c in 'zbuild-gh-get repos/o/r/labels' "zbuild-gh-get repos/o/r/labels '.[].name'" \
          "zbuild-gh-get 'repos/o/r/issues?state=all&per_page=100' '.[] | .name'" \
          'zbuild-gh-get "repos/o/r/labels" ".[] | select(.name == \"bug\") | .name"' \
          'zbuild-gh-get repos/o/r/branches/main/protection' "zbuild-gh-get 'repos/{owner}/{repo}/labels'"; do
    assert_eq "[RG4] allowed: $_c" "allow" "$(_dec "$(_ask "$_c" --gh-read)")"
done

print_test_section "RG5: no gh command line, and nothing around the wrapper"
for _c in 'gh api -iXPOST repos/o/r/labels' 'gh api -if title=x repos/o/r/issues' \
          'gh api -iX DELETE repos/o/r/git/refs/heads/main' 'gh api "-f" title=x repos/o/r/issues' \
          "gh api '-XPOST' repos/o/r/labels" 'gh api \-f title=x repos/o/r/issues' \
          'gh api -X POST repos/o/r/labels' 'gh api -f title=x repos/o/r/issues' 'gh api -X DELETE repos/o/r/git/refs/heads/main' \
          'gh api repos/o/r/labels' 'gh label list' 'gh issue view 3' \
          'zbuild-gh-get repos/o/r; rm x' 'zbuild-gh-get repos/o/r && ls' 'zbuild-gh-get repos/o/r | sh' \
          'zbuild-gh-get $(id)' 'zbuild-gh-get `id`' 'zbuild-gh-get "$GH_TOKEN"' 'zbuild-gh-get repos/o/r > out' \
          'zbuild-gh-get a b c' $'zbuild-gh-get repos/o/r\nrm x' 'zbuild-gh-get' 'zbuild-gh-get {a,b}' \
          "zbuild-gh-get 'a'\'' -X POST'" 'GH_TOKEN=x zbuild-gh-get repos/o/r' 'ls' \
          'zbuild-gh-get repos/o/r/issues?state=all' 'zbuild-gh-get ~/x' 'zbuild-gh-get repos/o/r #x' \
          'zbuild-gh-get "a\$b"' 'zbuild-gh-get repos/*/r' 'zbuild-gh-get "repos/o/r" .\[\]' 'command zbuild-gh-get repos/o/r'; do
    assert_eq "[RG5] refused: ${_c//$'\n'/\\n}" "deny" "$(_dec "$(_ask "$_c" --gh-read)")"
done
assert_contains "[RG5] ...told what may run" "$(_why "$(_ask 'gh label list' --gh-read)")" "zbuild-gh-get <endpoint> [jq-filter]"
assert_contains "[RG5] an unquoted query is told to quote it" "$(_why "$(_ask 'zbuild-gh-get repos/o/r/issues?state=all' --gh-read)")" "in single quotes"

print_test_section "RG6: with and without read-git"
assert_eq "[RG6] --gh-read alone: git is refused" "deny" "$(_dec "$(_ask 'git log -1' --gh-read)")"
assert_eq "[RG6] with --git-only too: git runs" "allow" "$(_dec "$(_ask 'git log -1' --git-only --gh-read)")"
assert_eq "[RG6] ...and the wrapper runs" "allow" "$(_dec "$(_ask 'zbuild-gh-get repos/o/r/labels' --git-only --gh-read)")"
assert_eq "[RG6] --git-only alone: the wrapper is refused" "deny" "$(_dec "$(_ask 'zbuild-gh-get repos/o/r/labels' --git-only)")"
assert_eq "[RG6] git diff --no-index reads any file: refused" "deny" "$(_dec "$(_ask "git diff --no-index $SECRET_DIR/token /dev/null" --git-only --gh-read)")"
assert_eq "[RG6] ...under read-git alone too" "deny" "$(_dec "$(_ask 'git diff --no-index a b' --git-only)")"
_g() { _ask "$1" --git-only --gh-read --secret-dir "$SECRET_DIR"; }
for _c in "git diff $SECRET_DIR/token /dev/null" "git diff '$SECRET_DIR/token' /dev/null" "git diff ${SECRET_DIR%/*} /dev/null" \
          'git diff $HOME/x /dev/null' 'git diff ~/x /dev/null' 'git diff ../../x /dev/null' "git -C ${SECRET_DIR%/*} diff a b" \
          'git diff /U*/x /dev/null' "git diff \"$SECRET_DIR\"/token /dev/null"; do
    assert_eq "[RG6] the token's file is out of git's reach: $_c" "deny" "$(_dec "$(_g "$_c")")"
done
for _c in 'git diff main..HEAD' 'git log -1 --stat' 'git show HEAD:core/x.sh' 'git diff main...HEAD -- core/'; do
    assert_eq "[RG6] ...git's reading still runs: $_c" "allow" "$(_dec "$(_g "$_c")")"
done

print_test_section "RG7: who gets it"
_words() { local _cw=""; manifest_call_words_v _cw "$REPO_ROOT/plugins/agent/$1/manifest.yaml" "$2" || _cw="<undeclared>"; printf '%s' " $_cw "; }
assert_contains "[RG7] issue-acceptance's call" "$(_words issue-acceptance main)" " read-github "
assert_contains "[RG7] the lens's own call" "$(_words review-lens main)" " read-github "
assert_contains "[RG7] the lens's check" "$(_words review-lens check)" " read-github "
for _p in build design test-author; do
    _lacks "[RG7] $_p's own call: none" "$(_words "$_p" main)" " read-github "
done

print_test_section "RG8: the rules say so"
_said=""; _route_tools_said_v _said "read-files read-git read-github"
assert_contains "[RG8] a judge with it is told the wrapper's form" "$_said" \
    "look GitHub up, read-only, with zbuild-gh-get <endpoint> [jq-filter] (a GET of GitHub's REST API"

print_test_section "RG9: no token in the model's environment"
assert_eq "[RG9] the token is in the secret folder" "$GH_TOKEN" "$(cat "$SECRET_DIR/token" 2>/dev/null)"
_mode="$(stat -c %a "$SECRET_DIR" 2>/dev/null || stat -f %Lp "$SECRET_DIR" 2>/dev/null)"
assert_eq "[RG9] ...a folder its owner only can open" "700" "$_mode"
_env="$( GITHUB_TOKEN=gt _route_call_env; printf 'GH=%s GITHUB=%s PATH0=%s' "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" "${PATH%%:*}" )"
assert_eq "[RG9] the call's environment has no token, the shim's folder first" "GH=unset GITHUB=unset PATH0=$_ROUTE_GH_BIN" "$_env"
_rd() { jq -cn --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p, path:$p}}' | bash "$HOOK" --gh-read --secret-dir "$SECRET_DIR" 0 ''; }
assert_eq "[RG9] reading the token file is refused" "deny" "$(_dec "$(_rd Read "$SECRET_DIR/token")")"
assert_eq "[RG9] ...so is searching a folder that holds it" "deny" "$(_dec "$(_rd Grep "${SECRET_DIR%/*}")")"
assert_eq "[RG9] ...or the root" "deny" "$(_dec "$(_rd Grep /)")"
assert_eq "[RG9] ...or a path through .." "deny" "$(_dec "$(_rd Read "$SECRET_DIR/../${SECRET_DIR##*/}/token")")"
assert_eq "[RG9] reading another file is not" "allow" "$(_dec "$(_rd Read "$ZBUILD_REPO_ROOT/README.md")")"
assert_eq "[RG9] ...nor searching the repository" "allow" "$(_dec "$(_rd Grep "$ZBUILD_REPO_ROOT")")"
unset GH_TOKEN GITHUB_TOKEN
_ROUTE_TOOLS_KEY="" ZBUILD_PLUGIN_DIR="$_lk" _route_call_tools_prepare >/dev/null 2>&1
_lacks "[RG9] no token in the environment: no secret folder" " ${_ROUTE_HOOK_FLAGS[*]:-} " " --secret-dir "
assert_eq "[RG9] ...and the shim still leads PATH" "$REPO_ROOT/core/router/gh-bin" "$( _route_call_env; printf '%s' "${PATH%%:*}" )"
unset GH_TOKEN

cleanup_test_env
print_test_results
exit $((FAIL > 0))
