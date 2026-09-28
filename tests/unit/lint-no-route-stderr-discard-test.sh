#!/usr/bin/env bash
# tests/unit/lint-no-route-stderr-discard-test.sh — drives scripts/lib/lint-stage-io.sh.
#
# ADR-015 §v4 (#491): the lint guard MUST flag any production callsite that
# combines `route_to_model[_loop]` or `run_captured_command` with `2>/dev/null`
# on the same line, and MUST be silent for callsites that don't.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-stage-io guard — same-line route_to_model + 2>/dev/null (#491)"
setup_test_env "lint-stage-io-guard"

LINT="$REPO_ROOT/scripts/lib/lint-stage-io.sh"

# TC-1: The lint script exists and is executable.
if [[ -x "$LINT" ]]; then
    assert_pass "TC-1: lint script is executable"
else
    assert_fail "TC-1: lint script is executable" "not executable: $LINT"
fi

# TC-2: Current repo passes the lint (post-#491 fix).
set +e
bash "$LINT" >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-2: lint passes on production tree" "0" "$rc"

# TC-3: Synthetic plugin with offending route_to_model line → rc=1.
mkdir -p "$TEST_TEMP_DIR/synth/plugin.sh.d"
SYNTH_BAD="$TEST_TEMP_DIR/synth/plugin.sh"
cat > "$SYNTH_BAD" <<'BAD'
#!/usr/bin/env bash
example_plugin_run() {
    raw_response="$(route_to_model T2 "$prompt" 2>/dev/null)" || rc=$?
}
BAD
set +e
bash "$LINT" "$SYNTH_BAD" >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-3: lint flags route_to_model + 2>/dev/null on plugin" "1" "$rc"

# TC-4: Synthetic plugin with offending route_to_model_loop → rc=1.
SYNTH_LOOP="$TEST_TEMP_DIR/synth-loop.sh"
cat > "$SYNTH_LOOP" <<'LOOP'
#!/usr/bin/env bash
build_run() {
    route_to_model_loop T2 "$f" "$repo" 5 --scope-allowlist "x" 2>/dev/null || rc=$?
}
LOOP
set +e
bash "$LINT" "$SYNTH_LOOP" >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-4: lint flags route_to_model_loop + 2>/dev/null" "1" "$rc"

# TC-5: Synthetic plugin with offending run_captured_command → rc=1.
SYNTH_RCC="$TEST_TEMP_DIR/synth-rcc.sh"
cat > "$SYNTH_RCC" <<'RCC'
#!/usr/bin/env bash
intake_run() {
    fetched="$(run_captured_command intake gh issue view 1 --json title 2>/dev/null)"
}
RCC
set +e
bash "$LINT" "$SYNTH_RCC" >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-5: lint flags run_captured_command + 2>/dev/null" "1" "$rc"

# TC-6: Clean plugin (no stderr suppression on the action line) → rc=0.
SYNTH_GOOD="$TEST_TEMP_DIR/synth-good.sh"
cat > "$SYNTH_GOOD" <<'GOOD'
#!/usr/bin/env bash
plan_run() {
    raw_response="$(route_to_model T2 "$prompt")" || rc=$?
}
GOOD
set +e
bash "$LINT" "$SYNTH_GOOD" >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-6: lint silent on clean callsite" "0" "$rc"

# TC-7: Unrelated 2>/dev/null on a non-route line → rc=0 (narrow scope).
SYNTH_UNRELATED="$TEST_TEMP_DIR/synth-unrelated.sh"
cat > "$SYNTH_UNRELATED" <<'UNRELATED'
#!/usr/bin/env bash
sample() {
    git status --porcelain 2>/dev/null
    gh repo view --json name 2>/dev/null || true
    raw="$(route_to_model T2 "$prompt")"
}
UNRELATED
set +e
bash "$LINT" "$SYNTH_UNRELATED" >/dev/null 2>&1
rc=$?
set -e
assert_eq "TC-7: lint ignores unrelated 2>/dev/null lines" "0" "$rc"

# TC-8: Error message mentions ADR-015 §v4 (operator-actionable).
SYNTH_MSG_OUT="$TEST_TEMP_DIR/lint-msg.txt"
set +e
bash "$LINT" "$SYNTH_BAD" >"$SYNTH_MSG_OUT" 2>&1
set -e
if grep -q "ADR-015" "$SYNTH_MSG_OUT" 2>/dev/null; then
    assert_pass "TC-8: error message references ADR-015"
else
    assert_fail "TC-8: error message references ADR-015" \
        "lint output: $(cat "$SYNTH_MSG_OUT")"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
