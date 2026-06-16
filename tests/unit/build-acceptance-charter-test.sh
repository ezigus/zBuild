#!/usr/bin/env bash
# Unit: build acceptance charter injection (ADR-031 / #866).
#
# AC1: build prompt contains the acceptance-charter section header.
# AC2: prompt contains each TESTFILES path from the design.md acceptance block.
# AC3: prompt contains explicit 'MUST NOT weaken' prohibition.
# AC4: behavioral — when the mocked router modifies an acceptance test file
#      that is NOT in plan.files[], build.scope.violation is emitted for it,
#      proving weakening an acceptance test is caught by the scope enforcer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build acceptance charter injection (ADR-031 / #866)"
setup_test_env "build-acceptance-charter-866"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-acceptance-charter-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

# Capture prompt via mock router (AC1/AC2/AC3 drive this).
export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── Shared stubs (AC1/AC2/AC3) ──────────────────────────────────────────────
# shellcheck disable=SC2317
route_to_model_loop() {
    local _prompt_file="$2"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_MOCK_ROUTE_CAPTURE"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    local in="$1" out="$2"
    [[ -f "$in" ]] && cp "$in" "$out"
    return 0
}

# Fresh git repo so `git diff HEAD` capture works.
_CHARTER_REPO="$TEST_TEMP_DIR/charter-repo"
mkdir -p "$_CHARTER_REPO"
( cd "$_CHARTER_REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$_CHARTER_REPO"

# Plan references one in-scope impl file.
ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
DIFF_PATCH="$ARTIFACT_DIR/diff.patch"
SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"

cat > "$PLAN_JSON" <<'JSON'
{
  "title": "843-C acceptance charter",
  "files": ["plugins/agent/build/plugin.sh"]
}
JSON
touch "$SCOPE_MANIFEST"

# design.md with an acceptance block listing two test files.
DESIGN_MD="$ARTIFACT_DIR/design.md"
cat > "$DESIGN_MD" <<'DESIGN'
# Design

Some design prose.

```acceptance
SPEC: build prompt must include acceptance charter section
SPEC: weakening acceptance test files triggers scope violation
TESTFILES:
tests/unit/build-acceptance-charter-test.sh
tests/unit/build-prompt-framing-test.sh
```

More prose.
DESIGN

# ─── AC1 / AC2 / AC3: drive _build_stage_run_inner; inspect captured prompt ──
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR
: > "$_MOCK_ROUTE_CAPTURE"

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON" \
    "$DIFF_PATCH" \
    "$SUMMARY_JSON" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc_charter=$?
set -e

assert_eq "setup: _build_stage_run_inner rc=0" "0" "$rc_charter"

captured_prompt="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"

# AC1: charter section header present.
if printf '%s' "$captured_prompt" | grep -qF "## ACCEPTANCE TESTS"; then
    assert_pass "AC1: prompt contains acceptance-charter section header"
else
    assert_fail "AC1: prompt must contain '## ACCEPTANCE TESTS' header" \
        "header not found in prompt"
fi

# AC2: each TESTFILES path appears in the prompt.
if printf '%s' "$captured_prompt" | grep -qF "tests/unit/build-acceptance-charter-test.sh"; then
    assert_pass "AC2a: prompt contains first TESTFILES path"
else
    assert_fail "AC2a: prompt must contain 'tests/unit/build-acceptance-charter-test.sh'" \
        "path not found in prompt"
fi
if printf '%s' "$captured_prompt" | grep -qF "tests/unit/build-prompt-framing-test.sh"; then
    assert_pass "AC2b: prompt contains second TESTFILES path"
else
    assert_fail "AC2b: prompt must contain 'tests/unit/build-prompt-framing-test.sh'" \
        "path not found in prompt"
fi

# AC3: explicit MUST NOT weaken prohibition present.
if printf '%s' "$captured_prompt" | grep -qF "MUST NOT weaken"; then
    assert_pass "AC3: prompt contains 'MUST NOT weaken' prohibition"
else
    assert_fail "AC3: prompt must contain 'MUST NOT weaken'" \
        "prohibition phrase not found in prompt"
fi

# ─── AC4: scope enforcer catches modification of acceptance test file ─────────
# Re-set events file for clean capture.
: > "$ZBUILD_EVENTS_JSONL"

# The acceptance test file is NOT in plan.files[]; the mocked router edits it
# to simulate the LLM "weakening" the test. The scope enforcer must emit
# build.scope.violation for that path.
ACCEPTANCE_TEST_FILE="tests/unit/build-acceptance-charter-test.sh"
mkdir -p "$_CHARTER_REPO/tests/unit"
echo "# original acceptance test" > "$_CHARTER_REPO/$ACCEPTANCE_TEST_FILE"
# Commit so it's tracked (scope post-validation uses git diff HEAD).
( cd "$_CHARTER_REPO" \
    && git add "$ACCEPTANCE_TEST_FILE" \
    && git commit -q -m "add acceptance test stub" ) >/dev/null

# Redefine route_to_model_loop to edit the acceptance test file (not in scope).
# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    # Simulate the LLM weakening the acceptance test (out-of-scope edit).
    printf '# WEAKENED — assert removed\n' > "$_repo/$ACCEPTANCE_TEST_FILE"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}

# Re-source the event bus so events land in our JSONL file.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON" \
    "$DIFF_PATCH" \
    "$SUMMARY_JSON" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc_ac4=$?
set -e

# The inner function returns 0 even on scope_violation (verdict written to summary).
assert_eq "AC4 setup: _build_stage_run_inner rc=0" "0" "$rc_ac4"

# Check that build.scope.violation was emitted for the acceptance test path.
violation_count="$(jq -r --arg p "$ACCEPTANCE_TEST_FILE" \
    'select(.type=="build.scope.violation") | select(.data.path==$p)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -c '"type"' || echo 0)"

if [[ "$violation_count" -ge 1 ]]; then
    assert_pass "AC4: build.scope.violation emitted for acceptance test file"
else
    assert_fail "AC4: build.scope.violation must fire for out-of-scope acceptance test edit" \
        "count=$violation_count in $ZBUILD_EVENTS_JSONL"
fi

# Also confirm build-summary.json records scope_violation=true.
summary_violation="$(jq -r '.scope_violation' "$SUMMARY_JSON" 2>/dev/null || echo 'null')"
if [[ "$summary_violation" == "true" ]]; then
    assert_pass "AC4: build-summary.json scope_violation=true"
else
    assert_fail "AC4: build-summary.json must have scope_violation=true" \
        "got scope_violation=$summary_violation"
fi

# ─── Helper unit: _build_read_acceptance_testfiles returns only paths ─────────
if declare -F _build_read_acceptance_testfiles >/dev/null 2>&1; then
    tf_out="$(_build_read_acceptance_testfiles "$DESIGN_MD" 2>/dev/null || true)"
    case "$tf_out" in
        *"tests/unit/build-acceptance-charter-test.sh"*)
            assert_pass "H1: _build_read_acceptance_testfiles returns first testfile" ;;
        *)
            assert_fail "H1: _build_read_acceptance_testfiles must return testfile paths" \
                "got: $tf_out" ;;
    esac
    # SPEC lines must NOT appear in testfiles output.
    case "$tf_out" in
        *"SPEC:"*)
            assert_fail "H2: _build_read_acceptance_testfiles must not return SPEC lines" \
                "got: $tf_out" ;;
        *)
            assert_pass "H2: _build_read_acceptance_testfiles omits SPEC lines" ;;
    esac
else
    assert_fail "H1: _build_read_acceptance_testfiles helper must exist" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
