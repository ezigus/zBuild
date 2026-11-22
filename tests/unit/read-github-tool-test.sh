#!/usr/bin/env bash
# tests/unit/read-github-tool-test.sh — read-github: a judge looks GitHub up,
# read-only (#2584 R6; ADR-017 §12, amended 2026-11-22).
#
# Why: on #1764 the engine claimed issues with a `zbuild:claimed` label that did
# not exist; the lenses read files and git only, so none could see it. The
# judging stages get a lookup of the outside world that writes nothing.
#
# RG1 [change] read-github is one of zbuild's words: a manifest naming it is valid
# RG2 [change] the Anthropic module gives it the shell, allowed only gh's reading
#              commands; with read-git it is one shell, allowed both
# RG3 [change] a call with read-github (and no run-commands) gets the hook's
#              --gh-read guard; a call that runs commands does not
# RG4 [change] the guard lets through: gh api GET (plain, -X GET, --method GET,
#              --paginate, --jq), gh issue view/list, gh pr view/list/diff/checks,
#              gh label list, gh repo view, gh release view/list, gh run view/list
# RG5 [change] it refuses: any other method, a field or an input (which make gh
#              api write), a header, a write command (issue edit, label create,
#              pr merge, …), --web, anything chained or redirected, a command
#              holding text that looks like a secret — each saying what may run
# RG6 [change] with --gh-read alone git is refused; with --git-only too, both run
# RG7 [change] who gets it: issue-acceptance's call and both of the lens's calls;
#              no building call
# RG8 [change] a judge with it is told it can look GitHub up with gh's reading
#              commands
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
assert_contains "[RG2] ...allowed gh api" "$(_after --allowedTools "$_a")" "Bash(gh api *)"
assert_contains "[RG2] ...and gh label list" "$(_after --allowedTools "$_a")" "Bash(gh label list *)"
_a="$(provider_anthropic_tool_args read-files read-git read-github 2>/dev/null)"
assert_eq "[RG2] with read-git: one shell" "Read,Grep,Glob,Bash" "$(_after --tools "$_a")"
assert_contains "[RG2] ...allowed git's readers" "$(_after --allowedTools "$_a")" "Bash(git diff *)"
assert_contains "[RG2] ...and gh's" "$(_after --allowedTools "$_a")" "Bash(gh issue view *)"

print_test_section "RG3: the hook's guard"
_flags() { _ROUTE_TOOLS_KEY="" ZBUILD_PLUGIN_DIR="$1" _route_call_tools_prepare >/dev/null 2>&1; printf '%s' "${_ROUTE_HOOK_FLAGS[*]:-}"; }
assert_contains "[RG3] a call with read-github is guarded" " $(_flags "$_lk") " " --gh-read "
_bd="$(_mk_plugin builder '  main: [read-files, edit-files, run-commands, read-github]
')"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_lacks "[RG3] a call that runs commands is not" " $(_flags "$_bd") " " --gh-read "

print_test_section "RG4: gh's reading commands run"
for _c in 'gh api repos/o/r/labels' 'gh api repos/o/r/labels --paginate --jq .[].name' 'gh api -X GET repos/o/r' \
          'gh api --method GET repos/o/r/branches/main/protection' 'gh api --method=GET repos/o/r' \
          'gh issue view 12 --json labels' 'gh issue list --label bug' 'gh pr view 3' 'gh pr list' 'gh pr diff 3' \
          'gh pr checks 3' 'gh label list' 'gh repo view o/r --json defaultBranchRef' 'gh release view v1' \
          'gh release list' 'gh run view 99' 'gh run list --limit 5' 'gh --repo o/r label list'; do
    assert_eq "[RG4] allowed: $_c" "allow" "$(_dec "$(_ask "$_c" --gh-read)")"
done

print_test_section "RG5: anything that writes is refused"
for _c in 'gh api -X POST repos/o/r/labels' 'gh api --method PATCH repos/o/r' 'gh api --method=DELETE repos/o/r' \
          'gh api -XPOST repos/o/r' 'gh api repos/o/r/labels -f name=x' 'gh api repos/o/r/labels -F name=x' \
          'gh api repos/o/r/labels --field name=x' 'gh api repos/o/r/labels --raw-field name=x' \
          'gh api repos/o/r/labels --input body.json' 'gh api -H X-HTTP-Method-Override:DELETE repos/o/r' \
          'gh api graphql' 'gh issue edit 3 --add-label x' 'gh label create zbuild:claimed' 'gh pr merge 3' \
          'gh issue comment 3 --body x' 'gh issue view 3 --web' 'gh label list; rm x' 'gh api x | sh' \
          'gh api x > out' 'gh api $(id)' 'gh auth token' 'gh secret list' 'ls' \
          'gh api repos/o/r?token=ghp_0123456789abcdefghijABCDEFGHIJ012345'; do
    assert_eq "[RG5] refused: $_c" "deny" "$(_dec "$(_ask "$_c" --gh-read)")"
done
assert_contains "[RG5] ...told what may run" "$(_why "$(_ask 'gh label create x' --gh-read)")" "gh api (GET only)"

print_test_section "RG6: with and without read-git"
assert_eq "[RG6] --gh-read alone: git is refused" "deny" "$(_dec "$(_ask 'git log -1' --gh-read)")"
assert_eq "[RG6] with --git-only too: git runs" "allow" "$(_dec "$(_ask 'git log -1' --git-only --gh-read)")"
assert_eq "[RG6] ...and gh runs" "allow" "$(_dec "$(_ask 'gh label list' --git-only --gh-read)")"
assert_eq "[RG6] --git-only alone: gh is refused" "deny" "$(_dec "$(_ask 'gh label list' --git-only)")"

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
assert_contains "[RG8] a judge with it is told it can look GitHub up" "$_said" \
    "look GitHub up with gh's reading commands (gh api GET, gh issue view, gh label list)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
