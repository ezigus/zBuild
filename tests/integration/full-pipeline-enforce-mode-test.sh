#!/usr/bin/env bash
# tests/integration/full-pipeline-enforce-mode-test.sh
# Wave 12-E (#664) — end-to-end: default mode is enforce.
#
# Scenario A: valid template (simple) with honest contracts (post 12-D)
#   - default mode (no env override) → contract validator passes
#     (the pipeline may still terminate downstream for other reasons; we
#      only assert that pre-flight does NOT refuse)
#
# Scenario B: broken template (broken-contract-missing-producer fixture) —
# build expects stage:plan but the template omits it (#979: reworked from the
# retired standard-missing-test/review→stage:test coupling).
#   - default mode (no env override) → runner rc=2 BEFORE any stage runs
#   - structured error printed on stderr
#   - pipeline.preflight.fail event emitted
#   - no plugin.run.start for intake (halts at pre-flight)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pipeline enforce-by-default — Wave 12-E (#664)"
setup_test_env "preflight-enforce-default"

# Install the broken-contract fixture for scenario B as a per-repo `.zbuild/templates/`
# overlay in a temp repo. #1270: the DRIVER runs with CWD = that repo (below), so
# the resolver reads the overlay from $PWD; nothing lands in the tracked
# config/templates/, and the temp repo is reaped by the master trap. Scenario A's
# `--template simple` has no per-repo override here, so it resolves the shipped
# simple template from the engine tree.
OVERLAY_REPO="$(setup_git_temp_repo tpl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" broken-contract-missing-producer

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="enforce-default-$$"
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR"
rm -f "$ZBUILD_STATE_FILE"

# Driver: source runner, call main() — explicitly UNSET the env var so we
# exercise the default-mode behavior (which Wave 12-E flips to enforce).
DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<DRV
set +e
unset ZBUILD_CONTRACT_VALIDATOR
source "$REPO_ROOT/core/pipeline/runner.sh"
set +e
main "\$@"
_rc=\$?
set -e
echo "EXIT_CODE=\$_rc"
exit \$_rc
DRV
chmod +x "$DRIVER"

# ── Scenario B: broken template → default mode refuses with rc=2 ────────────
err1="$TEST_TEMP_DIR/run1.err"
out1="$TEST_TEMP_DIR/run1.out"
( cd "$OVERLAY_REPO" && bash "$DRIVER" --goal "should be rejected" --template broken-contract-missing-producer ) \
    >"$out1" 2>"$err1" || true
exit_code1="$(grep -E '^EXIT_CODE=' "$out1" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")"

if [[ "$exit_code1" == "2" ]]; then
    assert_pass "default-mode: broken template → runner exits rc=2"
else
    assert_fail "default-mode: broken template → runner exits rc=2" \
        "got exit code '$exit_code1'; stderr-tail: $(tail -10 "$err1" 2>/dev/null | tr '\n' ' ')"
fi

if grep -q "Pipeline cannot start" "$err1" 2>/dev/null; then
    assert_pass "default-mode: structured error printed on stderr"
else
    assert_fail "default-mode: structured error printed on stderr" \
        "no 'Pipeline cannot start' in stderr"
fi

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    if jq -e 'select(.type == "plugin.run.start" and .stage == "intake")' \
        "$ZBUILD_EVENTS_JSONL" >/dev/null 2>&1; then
        assert_fail "default-mode: NO stage run before pre-flight failure" \
            "found plugin.run.start for intake — runner did not halt at pre-flight"
    else
        assert_pass "default-mode: NO plugin.run.start before pre-flight failure"
    fi
    if jq -e 'select(.type == "pipeline.preflight.fail")' \
        "$ZBUILD_EVENTS_JSONL" >/dev/null 2>&1; then
        assert_pass "default-mode: pipeline.preflight.fail event emitted"
    else
        assert_fail "default-mode: pipeline.preflight.fail event emitted" \
            "event not found"
    fi
fi

if [[ -f "$ZBUILD_STATE_FILE" ]]; then
    status_val="$(jq -r '.status' "$ZBUILD_STATE_FILE" 2>/dev/null || echo "")"
    assert_eq "default-mode: state stub status=preflight_failed" \
        "preflight_failed" "$status_val"
fi

# ── Scenario A: valid (honest) simple template → pre-flight passes ─────────
# Reset state, then drive the real simple template. The pipeline will
# likely terminate for unrelated reasons (no LLM mocks, network, etc.),
# but the contract validator must NOT print "Pipeline cannot start".
rm -f "$ZBUILD_STATE_FILE" "$ZBUILD_EVENTS_JSONL"
mkdir -p "$ZBUILD_EVENTS_DIR"

err2="$TEST_TEMP_DIR/run2.err"
out2="$TEST_TEMP_DIR/run2.out"
# --dry-run avoids actually running stages while still exercising pre-flight
( cd "$OVERLAY_REPO" && bash "$DRIVER" --goal "valid template smoke" --template simple --dry-run ) \
    >"$out2" 2>"$err2" || true

if grep -q "Pipeline cannot start" "$err2" 2>/dev/null; then
    assert_fail "default-mode: simple template passes pre-flight" \
        "pre-flight refused simple template; stderr-tail: $(tail -15 "$err2" 2>/dev/null)"
else
    assert_pass "default-mode: simple template passes pre-flight (honest contracts)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
