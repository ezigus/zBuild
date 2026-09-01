#!/usr/bin/env bash
# tests/integration/pipeline-preflight-missing-stage-test.sh
# ADR-020 (#496) keystone test.
#
# Invokes a real subprocess against a template that omits the `plan` stage.
# build's manifest declares `source: stage:plan` for its `plan` input, so the
# pre-flight validator MUST detect the missing producer. (#979: the fixture was
# reworked from the retired `review→stage:test` coupling to `build→stage:plan`
# after the standard lattice — and the `review` plugin — was deleted; same
# validator path, KEEP-set plugin.)
#
# Assertions (enforce mode):
#   - rc=2 from the runner (validator returns 2, runner propagates it)
#   - intake's `plugin.run.start` event is NOT emitted (halts BEFORE any stage)
#   - structured error on stderr names 'build' and 'plan'
#   - `pipeline.preflight.fail` event in events.jsonl
#
# Assertions (warn mode, default):
#   - structured error printed on stderr
#   - `pipeline.preflight.fail` event in events.jsonl
#   - pipeline does NOT exit 2 (warn mode allows continuation; the test
#     stops short of running real stages because that requires LLM mocks
#     beyond the scope of this keystone)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pipeline pre-flight keystone — missing plan producer (#496, ADR-020)"
setup_test_env "preflight-keystone"

# #1921 follow-up: reserved goal text, so the zbuild/state/goal-<hash> ref this
# run produces is traceable to a test. No repo isolation needed here — the driver
# already runs inside OVERLAY_REPO, and the template resolves through THAT repo's
# .zbuild overlay, so a cd of our own would break template resolution.
_ZB_GOAL="$(zb_test_goal preflight-missing-producer)"

# ── Pre-conditions: a fixture template that omits `plan` ────────────────────
# #1270: install the fixture as a per-repo `.zbuild/templates/` overlay in a temp
# repo. The DRIVER runs with CWD = that repo (below) so the resolver reads the
# overlay from $PWD; nothing lands in the tracked config/templates/, and the temp
# repo is reaped by the master trap (no source-tree leak on early exit).
OVERLAY_REPO="$(setup_git_temp_repo tpl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" broken-contract-missing-producer

# Shared environment: route state into the temp dir so the run is hermetic.
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="preflight-keystone-$$"
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR"

# The runner has a check that ZBUILD_STATE_FILE must be valid JSON if it
# exists; keep it absent so the runner initializes fresh state.
rm -f "$ZBUILD_STATE_FILE"

# ── Drive the runner via a tiny subshell harness (avoids the full CLI
# wrapper which sets up scope detection, gh fetch, etc., which require
# real network access). We call `main` from runner.sh directly.
DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<DRV
set +e
# Source the runner (set -euo pipefail is inherited) and invoke main().
source "$REPO_ROOT/core/pipeline/runner.sh"
set +e
ZBUILD_CONTRACT_VALIDATOR="\${ZBUILD_CONTRACT_VALIDATOR:-enforce}" \
    main --goal "$_ZB_GOAL" --template broken-contract-missing-producer
_rc=\$?
set -e
echo "EXIT_CODE=\$_rc"
exit \$_rc
DRV
chmod +x "$DRIVER"

# ── Run 1: enforce mode ────────────────────────────────────────────────────
err1="$TEST_TEMP_DIR/run1.err"
out1="$TEST_TEMP_DIR/run1.out"
( cd "$OVERLAY_REPO" && ZBUILD_CONTRACT_VALIDATOR=enforce bash "$DRIVER" ) >"$out1" 2>"$err1" || true
exit_code1="$(grep -E '^EXIT_CODE=' "$out1" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")"

if [[ "$exit_code1" == "2" ]]; then
    assert_pass "enforce: runner exits rc=2 on missing producer"
else
    assert_fail "enforce: runner exits rc=2 on missing producer" \
        "got exit code '$exit_code1'; stderr-tail: $(tail -10 "$err1" 2>/dev/null | tr '\n' ' ')"
fi

if grep -q "Pipeline cannot start" "$err1" 2>/dev/null; then
    assert_pass "enforce: structured error printed on stderr"
else
    assert_fail "enforce: structured error printed on stderr" \
        "no 'Pipeline cannot start' in stderr; err-tail: $(tail -5 "$err1" 2>/dev/null)"
fi

if grep -qE "(id=plan|stage 'plan')" "$err1" 2>/dev/null; then
    assert_pass "enforce: stderr names the missing producer/input"
else
    assert_fail "enforce: stderr names the missing producer/input" \
        "no 'plan' producer/input reference in stderr"
fi

# Pre-flight halts BEFORE intake runs — no plugin.run.start event for intake.
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    if jq -e 'select(.type == "plugin.run.start" and .stage == "intake")' \
        "$ZBUILD_EVENTS_JSONL" >/dev/null 2>&1; then
        assert_fail "enforce: NO stage run before pre-flight failure" \
            "found plugin.run.start for intake — runner did not halt at pre-flight"
    else
        assert_pass "enforce: NO plugin.run.start before pre-flight failure"
    fi
    if jq -e 'select(.type == "pipeline.preflight.fail")' "$ZBUILD_EVENTS_JSONL" >/dev/null 2>&1; then
        assert_pass "enforce: pipeline.preflight.fail event emitted"
    else
        assert_fail "enforce: pipeline.preflight.fail event emitted" \
            "event not found in $ZBUILD_EVENTS_JSONL"
    fi
else
    assert_fail "enforce: events.jsonl exists" "no events file written"
fi

# State stub written
if [[ -f "$ZBUILD_STATE_FILE" ]]; then
    status_val="$(jq -r '.status' "$ZBUILD_STATE_FILE" 2>/dev/null || echo "")"
    if [[ "$status_val" == "preflight_failed" ]]; then
        assert_pass "enforce: state stub status=preflight_failed"
    else
        assert_fail "enforce: state stub status=preflight_failed" \
            "got status='$status_val'"
    fi
else
    assert_fail "enforce: state stub written" "no state file"
fi

# ── Run 2: warn mode (default for first release) ───────────────────────────
# Reset state for the second run
rm -f "$ZBUILD_STATE_FILE" "$ZBUILD_EVENTS_JSONL"
mkdir -p "$ZBUILD_EVENTS_DIR"

err2="$TEST_TEMP_DIR/run2.err"
out2="$TEST_TEMP_DIR/run2.out"
( cd "$OVERLAY_REPO" && ZBUILD_CONTRACT_VALIDATOR=warn bash "$DRIVER" ) >"$out2" 2>"$err2" || true

if grep -q "Pipeline cannot start" "$err2" 2>/dev/null; then
    assert_pass "warn: structured error printed on stderr"
else
    assert_fail "warn: structured error printed on stderr" \
        "no 'Pipeline cannot start' in stderr"
fi

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    if jq -e 'select(.type == "pipeline.preflight.fail")' "$ZBUILD_EVENTS_JSONL" >/dev/null 2>&1; then
        assert_pass "warn: pipeline.preflight.fail event emitted"
    else
        assert_fail "warn: pipeline.preflight.fail event emitted" "event missing"
    fi
fi

# warn mode shouldn't have written a preflight_failed stub
if [[ -f "$ZBUILD_STATE_FILE" ]]; then
    status_val="$(jq -r '.status // empty' "$ZBUILD_STATE_FILE" 2>/dev/null || echo "")"
    if [[ "$status_val" != "preflight_failed" ]]; then
        assert_pass "warn: NO preflight_failed state stub (warn doesn't fail-closed)"
    else
        assert_fail "warn: NO preflight_failed state stub" \
            "warn mode wrote preflight_failed stub — should only happen in enforce"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
