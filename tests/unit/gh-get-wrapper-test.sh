#!/usr/bin/env bash
# tests/unit/gh-get-wrapper-test.sh — zbuild-gh-get, the one way a judge looks
# GitHub up (#2584 R6 review; ADR-017 §12, amended 2026-11-22).
#
# Why: the first read-github guard read gh's command line word by word, and let
# grouped and quoted flags through (`gh api -iXPOST …`, `"-f" title=x`, `\-f`):
# gh built POST and DELETE from them, under bypassPermissions, with CI's token.
# Now the model never builds a gh command line. It runs
# `zbuild-gh-get <endpoint> [jq-filter]`, and the wrapper builds gh's argv itself.
#
# GW1 [change] gh is run as `api --method GET --paginate [--jq=<filter>] --
#              <endpoint>`: a query with `&` and a filter with `|` are data
# GW2 [change] an endpoint that is not a plain REST path is refused before gh
#              runs: a flag, `..`, graphql, a character outside the safe set, a
#              third argument, no argument — each saying the form
# GW3 [change] no input makes a write: whatever the two arguments hold, gh gets
#              one --method, GET, and no field, input or header
# GW4 [change] gh gets the token from the file it was given (ZB_GH_TOKEN_FILE),
#              which the caller's environment does not hold
# GW5 [change] the reply passes through the scope redaction and the secret mask
#              (and the token itself is masked) before it is printed
# GW6 [change] a reply over the size cap is cut, saying so and how to narrow it
# GW7 [change] gh is killed at the time limit: rc 124, saying so
# GW8 [change] the shim zbuild-gh-get, found on PATH, runs the wrapper
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "zbuild-gh-get: a GET of GitHub's REST API, built by the engine (#2584)"
setup_test_env "gh-get-wrapper"

W="$REPO_ROOT/core/router/gh-get.sh"
SHIM="$REPO_ROOT/core/router/gh-bin"
ARGV="$TEST_TEMP_DIR/gh-argv" REPLY_F="$TEST_TEMP_DIR/gh-reply"
export ZB_TEST_GH_ARGV="$ARGV" ZB_TEST_GH_REPLY="$REPLY_F"
# The mocked gh: its argv one per line (a newline in one shown as \\n), the token it was given, then the reply.
mock_binary gh 'for _a in "$@"; do printf "%s\n" "${_a//$'"'"'\n'"'"'/\\n}"; done > "$ZB_TEST_GH_ARGV"; printf "TOKEN=%s\n" "${GH_TOKEN-unset}" >> "$ZB_TEST_GH_ARGV"
[[ -n "${ZB_TEST_GH_BLOCK:-}" ]] && read -r _ < "$ZB_TEST_GH_BLOCK"
cat "$ZB_TEST_GH_REPLY" 2>/dev/null; exit "${ZB_TEST_GH_RC:-0}"'
printf '[{"name":"bug"}]\n' > "$REPLY_F"
XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
( cd "$XR" && /usr/bin/git init -q ) >/dev/null 2>&1

_run() { rm -f "$ARGV"; ( cd "$XR" && bash "$W" "$@" ) > "$TEST_TEMP_DIR/out" 2> "$TEST_TEMP_DIR/err"; RC=$?; }
_argv() { /usr/bin/grep -v '^TOKEN=' "$ARGV" 2>/dev/null | tr '\n' '|'; }

print_test_section "GW1: gh's argv"
_run 'repos/o/r/issues?state=all&per_page=100' '.[] | .name'
assert_eq "[GW1] a query with & and a filter with |" \
    "api|--method|GET|--paginate|--jq=.[] | .name|--|repos/o/r/issues?state=all&per_page=100|" "$(_argv)"
assert_eq "[GW1] ...rc 0" "0" "$RC"
_run repos/o/r/labels
assert_eq "[GW1] no filter: no --jq" "api|--method|GET|--paginate|--|repos/o/r/labels|" "$(_argv)"
_run '/repos/{owner}/{repo}/labels'
assert_eq "[GW1] gh's {owner}/{repo} and a leading /" "api|--method|GET|--paginate|--|repos/{owner}/{repo}/labels|" "$(_argv)"
assert_contains "[GW1] the reply is printed" "$(cat "$TEST_TEMP_DIR/out")" '[{"name":"bug"}]'

print_test_section "GW2: an endpoint that is not a plain REST path"
for _e in '-XPOST' '--method=POST' '-f' '--input=x' '--watch' '--interval=1' 'graphql' '/graphql' \
          'repos/../user' 'repos/o/r/..' './repos' 'repos/o/r;rm' 'repos/o/r labels' 'repos/o/r?a=b;c' \
          'repos/o/r?-f=x' 'repos/o/r?a' 'https://evil.example/x' 'repos/o/r#x' '' 'repos//o'; do
    _run "$_e"
    assert_eq "[GW2] refused: '$_e'" "2|<gh not run>" "$RC|$([[ -e "$ARGV" ]] && echo ran || echo '<gh not run>')"
done
_run a b c
assert_eq "[GW2] a third argument: refused" "2|<gh not run>" "$RC|$([[ -e "$ARGV" ]] && echo ran || echo '<gh not run>')"
_run
assert_eq "[GW2] no argument: refused" "2" "$RC"
assert_contains "[GW2] ...saying the form" "$(cat "$TEST_TEMP_DIR/err")" "zbuild-gh-get <endpoint> [jq-filter]"

print_test_section "GW3: no write, whatever the arguments hold"
for _f in '-X POST' '--method=DELETE' '-f title=x' '--input=/etc/passwd' '-H X-HTTP-Method-Override:DELETE' $'.\n-XPOST'; do
    _run repos/o/r/labels "$_f"
    _a="$(_argv)"
    _n="$(/usr/bin/grep -cE '^(-X|--method)' "$ARGV" 2>/dev/null)"
    assert_eq "[GW3] filter '${_f//$'\n'/\\n}': one --method, GET" "1|GET" "$_n|$(/usr/bin/grep -A1 -x -- '--method' "$ARGV" 2>/dev/null | tail -n 1)"
    if /usr/bin/grep -qE '^(-f|-F|--field|--raw-field|--input|-H|--header)' "$ARGV" 2>/dev/null; then
        assert_fail "[GW3] filter '${_f//$'\n'/\\n}': no field, input or header" "$_a"
    else
        assert_pass "[GW3] filter '${_f//$'\n'/\\n}': no field, input or header"
    fi
done

print_test_section "GW4: the token comes from its file"
printf 'ghs_fromthefile0123456789' > "$TEST_TEMP_DIR/token"
( export ZB_GH_TOKEN_FILE="$TEST_TEMP_DIR/token"; unset GH_TOKEN GITHUB_TOKEN; _run repos/o/r )
assert_eq "[GW4] gh is given the file's token" "TOKEN=ghs_fromthefile0123456789" "$(/usr/bin/grep '^TOKEN=' "$ARGV" 2>/dev/null)"

print_test_section "GW5: the reply is redacted"
printf 'see %s and password=hunter2hunter2 and ghs_fromthefile0123456789\n' ".env.production" > "$REPLY_F"
( export ZB_GH_TOKEN_FILE="$TEST_TEMP_DIR/token"; _run repos/o/r/contents )
_o="$(cat "$TEST_TEMP_DIR/out")"
assert_contains "[GW5] a private path is redacted" "$_o" "see <private> and"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_lacks "[GW5] a credential is masked" "$_o" "hunter2hunter2"
_lacks "[GW5] the token itself is masked" "$_o" "ghs_fromthefile0123456789"

print_test_section "GW6: the size cap"
printf '%*s\n' 500 '' | tr ' ' 'x' > "$REPLY_F"
( export ZB_GH_GET_MAX=100; _run repos/o/r )
_o="$(cat "$TEST_TEMP_DIR/out")"
assert_eq "[GW6] the reply is cut at the cap" "$(printf '%*s' 100 '' | tr ' ' x)" "$(head -n 1 <<< "$_o")"
assert_contains "[GW6] ...saying so and how to narrow it" "$_o" "narrow it with a jq filter"

print_test_section "GW7: the time limit"
mkfifo "$TEST_TEMP_DIR/block"
( export ZB_TEST_GH_BLOCK="$TEST_TEMP_DIR/block" ZB_GH_GET_TIMEOUT=1; _run repos/o/r; printf '%s' "$RC" > "$TEST_TEMP_DIR/rc" )
assert_eq "[GW7] gh is killed at the limit: rc 124" "124" "$(cat "$TEST_TEMP_DIR/rc" 2>/dev/null)"
assert_contains "[GW7] ...saying so" "$(cat "$TEST_TEMP_DIR/err")" "did not answer within 1 seconds"

print_test_section "GW8: the shim"
printf '[]\n' > "$REPLY_F"
rm -f "$ARGV"
( cd "$XR" && PATH="$SHIM:$PATH" zbuild-gh-get repos/o/r/labels ) >/dev/null 2>&1
assert_eq "[GW8] zbuild-gh-get on PATH runs the wrapper" "api|--method|GET|--paginate|--|repos/o/r/labels|" "$(_argv)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
