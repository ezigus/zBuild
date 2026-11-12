#!/usr/bin/env bash
# Tests: scripts/lib/lint-test-determinism.sh (ADR-012 amendment 2026-11-08,
# "tests are deterministic").
#
# A test never depends on a remote service or on a clock. In tests/ and in each
# plugin's tests/, the lint fails on:
#   T1  a call to gh, claude, curl or wget in a file that installs no mock for it
#   T2  ...and passes when the file installs one (mock_gh, mock_binary gh, a
#       script written to <dir>/bin/gh, install_envelope_mock_claude, ...)
#   T3  a call by absolute path (/usr/bin/curl), which goes past any mock
#   T4  text that only mentions the name: comments, strings, heredoc bodies
#       (where mocks are written), `command -v gh`
#   T5  a `sleep` followed, within three commands, by a `kill` (sleep-then-kill)
#   T6  ...and passes a poll loop, a background sleeper (`sleep 30 &`), `kill -0`
#       (a liveness check) and a kill further away
#   T7  a line marked `# determinism-ok: <reason>` passes; a mark with no reason
#       fails
#   T8  files outside tests/ and plugins/*/tests/ are not scanned
#   T9  the baseline: a listed finding passes, a new finding fails, a listed
#       finding that is gone fails (the list only shrinks)
#   T10 the real tree passes, and `npm run lint` runs the lint
#   T11 a test that reads the clock to see how long something took ($SECONDS,
#       date +%s) fails; a mention in a comment or string does not (#2525: on
#       #1805 run 43093018140 a busy machine made a 15 s bound 16 s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "lint-test-determinism — tests depend on no remote service and no clock"
setup_test_env "lint-test-determinism"
_test_cleanup_hook() { cleanup_test_env; }

LINT="$REPO_ROOT/scripts/lib/lint-test-determinism.sh"

# _lint <file under root> <body> [baseline] — run the lint on a fresh tree
# holding one file with that body (and that baseline); print `rc=<rc>` then the
# lint's output.
_lint() {
    local root; root="$(mktemp -d "$TEST_TEMP_DIR/root.XXXXXX")"
    mkdir -p "$root/${1%/*}" "$root/config"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$root/$1"
    [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$root/config/test-determinism-baseline.txt"
    local out rc=0
    out="$(bash "$LINT" "$root" 2>&1)" || rc=$?
    printf 'rc=%s\n%s\n' "$rc" "$out"
}
_rc() { local o; o="$(_lint "$@")"; printf '%s' "${o%%$'\n'*}"; }
U=tests/unit/x-test.sh

print_test_section "T1: a remote call with no mock fails"
_t1="$(_lint "$U" 'gh pr view 12 --json title')"
assert_eq "[T1] gh with no mock fails" "rc=1" "${_t1%%$'\n'*}"
assert_contains "[T1] the failure names the file and line" "$_t1" "tests/unit/x-test.sh:2"
assert_contains "[T1] ...and the command" "$_t1" "gh"
assert_eq "[T1] claude"           "rc=1" "$(_rc "$U" 'out="$(claude -p "hi")"')"
assert_eq "[T1] curl"             "rc=1" "$(_rc "$U" 'curl -s https://example.com')"
assert_eq "[T1] wget"             "rc=1" "$(_rc "$U" 'wget -q https://example.com')"
assert_eq "[T1] after &&"         "rc=1" "$(_rc "$U" 'true && gh issue list')"
assert_eq "[T1] after if"         "rc=1" "$(_rc "$U" 'if gh auth status; then :; fi')"
assert_eq "[T1] in a plugin's tests/" "rc=1" "$(_rc plugins/tool/x/tests/x-test.sh 'gh pr list')"
assert_eq "[T1] in tests/integration/" "rc=1" "$(_rc tests/integration/x-test.sh 'gh pr list')"

print_test_section "T2: a remote call the file mocks passes"
assert_eq "[T2] mock_gh"          "rc=0" "$(_rc "$U" $'mock_gh \'echo ok\'\ngh pr view 12')"
assert_eq "[T2] mock_binary gh"   "rc=0" "$(_rc "$U" $'mock_binary "gh" \'echo ok\'\ngh pr view 12')"
assert_eq "[T2] a script written to bin/gh" "rc=0" \
    "$(_rc "$U" $'printf \'#!/bin/sh\\n\' > "$TEST_TEMP_DIR/bin/gh"\ngh pr view 12')"
assert_eq "[T2] install_envelope_mock_claude" "rc=0" \
    "$(_rc "$U" $'install_envelope_mock_claude ok\nclaude -p hi')"
assert_eq "[T2] a mock of gh does not cover curl" "rc=1" \
    "$(_rc "$U" $'mock_gh \'echo ok\'\ncurl -s https://example.com')"

print_test_section "T3: a call by absolute path fails, mock or not"
assert_eq "[T3] /usr/bin/curl"    "rc=1" "$(_rc "$U" $'mock_anthropic_api\n/usr/bin/curl -s https://example.com')"
assert_eq "[T3] /usr/local/bin/gh" "rc=1" "$(_rc "$U" $'mock_gh x\n/usr/local/bin/gh pr list')"
assert_eq "[T3] a path with a hyphen in it (review on #2500)" "rc=1" \
    "$(_rc "$U" $'mock_gh x\n/opt/my-tool/bin/gh pr list')"

print_test_section "T4: mentions of the name pass"
assert_eq "[T4] a comment"        "rc=0" "$(_rc "$U" '# gh pr create used to refuse here')"
assert_eq "[T4] a trailing comment" "rc=0" "$(_rc "$U" 'x=1  # then gh pr view')"
assert_eq "[T4] a string"         "rc=0" "$(_rc "$U" 'echo "run gh pr view to see it"')"
assert_eq "[T4] single quotes"    "rc=0" "$(_rc "$U" "assert_contains x \"\$o\" 'gh pr create'")"
assert_eq "[T4] a heredoc body (where a mock is written)" "rc=0" \
    "$(_rc "$U" $'cat > "$d/curl" <<\'EOF\'\n#!/usr/bin/env bash\nexec /usr/bin/curl "$@"\nEOF')"
assert_eq "[T4] command -v gh"    "rc=0" "$(_rc "$U" 'command -v gh >/dev/null || exit 0')"
assert_eq "[T4] a name that contains it" "rc=0" "$(_rc "$U" 'ghost=1; curly_brace x; claude_mock y')"

print_test_section "T5: sleep-then-kill fails"
_t5="$(_lint "$U" $'( run_push ) &\npid=$!\nsleep 0.1\nkill -KILL "$pid" 2>/dev/null || true')"
assert_eq "[T5] sleep, then kill" "rc=1" "${_t5%%$'\n'*}"
assert_contains "[T5] the failure names the sleep's line" "$_t5" "tests/unit/x-test.sh:4"
assert_eq "[T5] ...with a command between" "rc=1" \
    "$(_rc "$U" $'sleep 1\necho waiting\nkill -TERM "$pid"')"
assert_eq "[T5] ...indented, in an if" "rc=1" \
    "$(_rc "$U" $'if ready; then\n    sleep 1\n    kill -TERM "$pid"\nfi')"

print_test_section "T6: waiting on a condition passes"
assert_eq "[T6] a one-line poll loop" "rc=0" \
    "$(_rc "$U" $'for _ in $(seq 1 100); do [[ -s "$f" ]] && break; sleep 0.05; done\nkill -TERM "$pid"')"
assert_eq "[T6] a multi-line poll loop" "rc=0" \
    "$(_rc "$U" $'while [[ ! -s "$f" ]]; do\n    sleep 0.1\ndone\nkill -TERM "$pid"')"
assert_eq "[T6] a background sleeper" "rc=0" "$(_rc "$U" $'sleep 30 &\np=$!\nkill "$p"')"
assert_eq "[T6] kill -0 is a liveness check" "rc=0" \
    "$(_rc "$U" $'sleep 0.2\nkill -0 "$pid" && alive=1')"
assert_eq "[T6] ...and so is kill -s 0 (review on #2500)" "rc=0" \
    "$(_rc "$U" $'sleep 0.2\nkill -s 0 "$pid" && alive=1')"
assert_eq "[T6] a kill more than three commands later" "rc=0" \
    "$(_rc "$U" $'sleep 1\na\nb\nc\nkill "$pid"')"

print_test_section "T7: the determinism-ok mark"
assert_eq "[T7] a mark with a reason on the sleep passes" "rc=0" \
    "$(_rc "$U" $'sleep 0.3  # determinism-ok: asserts nothing happens in 0.3s\nkill -KILL "$p"')"
assert_eq "[T7] ...or on the kill" "rc=0" \
    "$(_rc "$U" $'sleep 0.3\nkill -KILL "$p"  # determinism-ok: clean-up only')"
assert_eq "[T7] ...or on a remote call" "rc=0" \
    "$(_rc "$U" 'gh --version  # determinism-ok: a local version query')"
assert_eq "[T7] a mark with no reason fails" "rc=1" \
    "$(_rc "$U" 'gh pr list  # determinism-ok:')"

print_test_section "T8: only tests are scanned"
assert_eq "[T8] scripts/ is not a test" "rc=0" "$(_rc scripts/lib/x.sh 'gh pr list')"
assert_eq "[T8] a plugin's own code is not a test" "rc=0" "$(_rc plugins/tool/x/plugin.sh $'sleep 1\nkill "$p"')"

print_test_section "T9: the baseline only shrinks"
_body=$'sleep 0.1\nkill -KILL "$pid"'
assert_eq "[T9] a listed finding passes" "rc=0" \
    "$(_rc "$U" "$_body" $'# header\nsleep-kill|tests/unit/x-test.sh|sleep 0.1')"
_t9="$(_lint "$U" "$_body"$'\ngh pr list' $'sleep-kill|tests/unit/x-test.sh|sleep 0.1')"
assert_eq "[T9] a new finding in a listed file fails" "rc=1" "${_t9%%$'\n'*}"
assert_contains "[T9] ...naming the new one" "$_t9" "tests/unit/x-test.sh:4"
_t9s="$(_lint "$U" 'echo fixed' $'sleep-kill|tests/unit/x-test.sh|sleep 0.1')"
assert_eq "[T9] a listed finding that is gone fails" "rc=1" "${_t9s%%$'\n'*}"
assert_contains "[T9] ...telling you to remove the entry" "$_t9s" "remove"

print_test_section "T11: a test reads no clock"
assert_eq "[T11] \$SECONDS read to time something fails" "rc=1" "$(_rc "$U" $'_t0=$SECONDS\nrun_it\n_took=$(( SECONDS - _t0 ))')"
assert_contains "[T11] ...saying why" "$(_lint "$U" '_t0=$SECONDS')" "reads the clock"
assert_eq "[T11] date +%s fails" "rc=1" "$(_rc "$U" 'start="$(date +%s)"')"
assert_eq "[T11] a comment that mentions SECONDS passes" "rc=0" "$(_rc "$U" '# the old test read $SECONDS here')"
assert_eq "[T11] a line marked determinism-ok passes" "rc=0" "$(_rc "$U" '_t0=$SECONDS  # determinism-ok: a run id, not a timing')"

print_test_section "T10: the real tree"
_rc_t=0; _out_t="$(bash "$LINT" "$REPO_ROOT" 2>&1)" || _rc_t=$?
assert_eq "[T10] the repository passes the lint" "0" "$_rc_t"
[[ "$_rc_t" -eq 0 ]] || printf '%s\n' "$_out_t" >&2
assert_contains "[T10] npm run lint runs it" \
    "$(jq -r '.scripts.lint' "$REPO_ROOT/package.json")" "bash scripts/lib/lint-test-determinism.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
