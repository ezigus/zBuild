#!/usr/bin/env bash
# tests/unit/stage-budget-note-test.sh — every model stage is told its limits
# (#2252 E, folds the budget-note half of #2222).
#
# Why: a model that does not know its deadline works until it is killed, and a
# killed call returns nothing. Seven stages carry their own note; issue-acceptance,
# security-lens, spec-coverage, spec-correspondence and impact had none rendered
# from the limits the engine enforces, and build's lacked the "finish by ~70%"
# line the others give.
#
# N1 [change] the shared note states the wall clock from the enforcing value and
#             a ~70% finish target
# N2 [change] it states the turn cap when there is one, and omits it at 0
#             (no cap)
# N3 [change] it tells the model a partial answer that names its gaps beats
#             being stopped with nothing
# N4 [change] every plugin that calls a model renders a budget note
# N5 [change] build's note carries the ~70% finish target
# N6 [change] the note reaches the text actually sent to the model (driven
#             through spec-correspondence's model call)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every model stage is told its limits (#2252 E)"
setup_test_env "stage-budget-note"

# shellcheck source=../../scripts/lib/stage-budget-note.sh
source "$REPO_ROOT/scripts/lib/stage-budget-note.sh" 2>/dev/null || true
# The enforcing values, as the router resolves them for the dispatched stage.
_route_resolve_timeout() { printf '600'; }
_route_resolve_max_turns() { printf '20'; }

print_test_section "N1-N3: the shared note"
NOTE="$(stage_budget_note "your report" 2>/dev/null)"
assert_contains "[N1] states the wall clock" "$NOTE" "600 seconds"
assert_contains "[N1] ...and a ~70% finish target" "$NOTE" "420s"
assert_contains "[N2] states the turn cap" "$NOTE" "20 tool-call turns"
assert_contains "[N3] a partial answer beats nothing" "$NOTE" "names its gaps"
_route_resolve_max_turns() { printf '0'; }
if grep -q 'tool-call turns' <<< "$(stage_budget_note "x" 2>/dev/null)"; then
    assert_fail "[N2] no turn cap (0) → no turn note" "turn note rendered"
else
    assert_pass "[N2] no turn cap (0) → no turn note"
fi

print_test_section "N4-N5: every model-calling stage"
while IFS= read -r d; do
    p="$(basename "$d")"
    calls="$(grep -rlE 'route_to_model(_loop)? "' "$d" --include='*.sh' 2>/dev/null | grep -v '/tests/' || true)"
    [[ -n "$calls" ]] || continue
    if grep -rqE 'stage_budget_note|_budget_guidance|_wallclock_guidance|_budget_wall' "$d" --include='*.sh' 2>/dev/null; then
        assert_pass "[N4] $p renders a budget note"
    else
        assert_fail "[N4] $p renders a budget note" "calls a model, states no limit"
    fi
done < <(find "$REPO_ROOT/plugins" -mindepth 2 -maxdepth 2 -type d | sort)
assert_contains "[N5] build's note carries the ~70% finish target" \
    "$(cat "$REPO_ROOT/plugins/agent/build/lib/prompt.sh")" '_budget_wall * 70 / 100'

print_test_section "N6: the note is in what the model receives"
_n6="$(
    # shellcheck source=../../plugins/agent/spec-correspondence/plugin.sh
    source "$REPO_ROOT/plugins/agent/spec-correspondence/plugin.sh" >/dev/null 2>&1
    _route_resolve_timeout() { printf '300'; }
    _route_resolve_max_turns() { printf '0'; }
    route_to_model() { printf '%s' "$2" > "$TEST_TEMP_DIR/n6-prompt.txt"; printf '{}'; }
    persona_stage_framing() { return 1; }
    _sc_call T2 "judge these SPECs" >/dev/null 2>&1
    cat "$TEST_TEMP_DIR/n6-prompt.txt" 2>/dev/null
)"
assert_contains "[N6] the task is sent" "$_n6" "judge these SPECs"
assert_contains "[N6] ...with the wall clock note" "$_n6" "300 seconds"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
