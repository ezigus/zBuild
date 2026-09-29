#!/usr/bin/env bash
# tests/unit/stage-signal-test.sh — stop-reason words are chosen once, not per
# plugin (#2225 §2).
#
# Why: each plugin hand-picked its own word and its own trap. #1837's intake
# wrote `broken` on SIGTERM (halts the run; a signal is `interrupted`, which
# retries) and `unavailable` for a CLOSED issue (nothing was down). deploy,
# monitor, review-lens and security-lens each carried a TERM/INT trap with
# different save/restore behaviour.
#
# G1 [change] stage_signal_begin: a TERM runs the stage's callback with the one
#             word for it — interrupted / signal_interrupt
# G2 [change] stage_signal_end puts the caller's own handler back
# G3 [change] lint-stage-signals refuses a raw TERM/INT trap in a plugin, and
#             passes the helper and an annotated (# signal-ok:) trap
# G4 [change] lint-disposition-words refuses a literal `unavailable` with no
#             # disposition-ok: note naming the service, and passes an annotated one
# G6 [change] a second stage_signal_begin before stage_signal_end is refused, and
#             the first guard still restores the caller's handler (review #2229:
#             nesting overwrote the saved handler and swallowed later signals)
# G5 [change] the real tree passes both (every plugin uses the helper; every
#             `unavailable` names its service)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stop-reason words chosen once: the signal helper and its lints (#2225 §2)"
setup_test_env "stage-signal"

print_test_section "G1/G2: the helper"
if [[ -f "$REPO_ROOT/scripts/lib/stage-signal.sh" ]]; then
    _out="$(
        # shellcheck source=../../scripts/lib/stage-signal.sh
        source "$REPO_ROOT/scripts/lib/stage-signal.sh"
        _cb() { printf 'CB %s %s\n' "$1" "$2"; }
        trap 'printf "CALLER\n"' TERM
        stage_signal_begin _cb
        kill -TERM "$BASHPID"
        stage_signal_end
        trap -p TERM
    )"
    assert_contains "[G1] a TERM runs the callback with interrupted / signal_interrupt" "$_out" "CB interrupted signal_interrupt"
    assert_contains "[G2] the caller's own TERM handler is back afterwards" "$_out" "CALLER"
else
    assert_fail "[G1] scripts/lib/stage-signal.sh exists" "missing"
    assert_fail "[G2] scripts/lib/stage-signal.sh exists" "missing"
fi

print_test_section "G6: no nesting"
if [[ -f "$REPO_ROOT/scripts/lib/stage-signal.sh" ]]; then
    _out6="$(
        # shellcheck source=../../scripts/lib/stage-signal.sh
        source "$REPO_ROOT/scripts/lib/stage-signal.sh"
        _cb() { :; }
        trap 'printf "CALLER\n"' TERM
        stage_signal_begin _cb
        if stage_signal_begin _cb 2>/dev/null; then printf 'nested=accepted\n'; else printf 'nested=refused\n'; fi
        stage_signal_end
        trap -p TERM
    )"
    assert_contains "[G6] a nested begin is refused" "$_out6" "nested=refused"
    assert_contains "[G6] ...and the caller's handler is still restored" "$_out6" "CALLER"
fi

print_test_section "G3: lint-stage-signals"
P="$TEST_TEMP_DIR/plugins/agent/x"; mkdir -p "$P"
_lint_sig() { bash "$REPO_ROOT/scripts/lib/lint-stage-signals.sh" "$TEST_TEMP_DIR/plugins" >/dev/null 2>&1; echo $?; }
printf 'f() { trap "h" TERM INT; g; trap - TERM INT; }\n' > "$P/plugin.sh"
assert_eq "[G3] a raw TERM/INT trap in a plugin is refused" "1" "$(_lint_sig)"
printf 'f() { stage_signal_begin h; g; stage_signal_end; }\n' > "$P/plugin.sh"
assert_eq "[G3] the helper passes" "0" "$(_lint_sig)"
printf 'f() {\n    # signal-ok: forwards to a child process group\n    trap "h" TERM\n}\n' > "$P/plugin.sh"
assert_eq "[G3] an annotated trap passes" "0" "$(_lint_sig)"

print_test_section "G4: lint-disposition-words and unavailable"
Q="$TEST_TEMP_DIR/plugins2/tool/y"; mkdir -p "$Q"
_lint_words() { bash "$REPO_ROOT/scripts/lib/lint-disposition-words.sh" "$TEST_TEMP_DIR/plugins2" >/dev/null 2>&1; echo $?; }
printf 'jq -n %s\n' "'{\"disposition\":\"unavailable\",\"reason\":\"closed\"}'" > "$Q/plugin.sh"
assert_eq "[G4] an unexplained unavailable is refused" "1" "$(_lint_words)"
{ printf '# disposition-ok: GitHub is not responding (push failed)\n'
  printf 'jq -n %s\n' "'{\"disposition\":\"unavailable\",\"reason\":\"push\"}'"; } > "$Q/plugin.sh"
assert_eq "[G4] an annotated unavailable passes" "0" "$(_lint_words)"

print_test_section "G5: the real tree"
assert_eq "[G5] every plugin's signal handling uses the helper" "0" \
    "$(bash "$REPO_ROOT/scripts/lib/lint-stage-signals.sh" >/dev/null 2>&1; echo $?)"
assert_eq "[G5] every literal unavailable names its service" "0" \
    "$(bash "$REPO_ROOT/scripts/lib/lint-disposition-words.sh" >/dev/null 2>&1; echo $?)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
