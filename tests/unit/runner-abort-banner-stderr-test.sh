#!/usr/bin/env bash
# tests/unit/runner-abort-banner-stderr-test.sh — the abort banner reaches the
# runner's stderr however the signal lands (ADR-054 §7).
#
# A trap that fires inside a call made with 2>/dev/null runs under that
# redirect: when SIGTERM landed during such a call in the runner's own shell,
# the EXIT trap's "Pipeline aborted" banner went to /dev/null
# (core-pipeline-runner I6, 2 in 36 runs under load).
#
# B1 [change] _runner_restore_stderr, called inside a 2>/dev/null call, sends
#             what follows to the runner's own stderr
# B2 [guard]  …and is a no-op when no stderr was saved
# B3 [change] the abort trap restores stderr before anything else
# B4 [change] the runner saves its stderr before it installs the EXIT trap
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the abort banner reaches stderr (ADR-054 §7)"
setup_test_env "runner-abort-banner-stderr"

RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../core/pipeline/runner.sh
source "$RUNNER" >/dev/null 2>&1
set +e   # runner.sh turns errexit on; this test reports its failures instead

print_test_section "B1/B2: _runner_restore_stderr"
ERR="$TEST_TEMP_DIR/err"
(
    exec 2>"$ERR"
    exec {_RUNNER_ERR_FD}>&2
    _inner() { _runner_restore_stderr; printf 'BANNER\n' >&2; }
    _inner 2>/dev/null
) 2>/dev/null
assert_eq "[B1] what follows it inside a silenced call reaches the saved stderr" "BANNER" "$(cat "$ERR" 2>/dev/null)"
(
    exec 2>"$ERR"
    unset _RUNNER_ERR_FD
    _inner() { _runner_restore_stderr; printf 'QUIET\n' >&2; }
    _inner 2>/dev/null
    printf 'rc=%s\n' "$?" >&2
) 2>/dev/null
assert_eq "[B2] with nothing saved the redirect stands, and it returns 0" "rc=0" "$(cat "$ERR" 2>/dev/null)"

print_test_section "B3/B4: where the runner uses it"
trap_body="$(awk '/^    _runner_abort_trap\(\) \{/{f=1} f{print} f && /^    \}$/{exit}' "$RUNNER")"
first_stmt="$(printf '%s\n' "$trap_body" | sed 1d | grep -vE '^\s*(#|$)' | head -1 | sed 's/^ *//')"
assert_eq "[B3] the abort trap's first statement restores stderr" "_runner_restore_stderr" "$first_stmt"
_save_ln="$(grep -n 'exec {_RUNNER_ERR_FD}>&2' "$RUNNER" | head -1 | cut -d: -f1)"
_trap_ln="$(grep -n "trap '_runner_abort_trap' EXIT" "$RUNNER" | head -1 | cut -d: -f1)"
if [[ -n "$_save_ln" && -n "$_trap_ln" && "$_save_ln" -lt "$_trap_ln" ]]; then
    assert_pass "[B4] stderr is saved (line $_save_ln) before the EXIT trap is set (line $_trap_ln)"
else
    assert_fail "[B4] stderr is saved before the EXIT trap is set" "save=${_save_ln:-none} trap=${_trap_ln:-none}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
