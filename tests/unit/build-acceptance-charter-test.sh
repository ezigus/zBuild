#!/usr/bin/env bash
# Unit: build acceptance charter injection (ADR-031 / #866).
#
# AC1: build prompt contains the acceptance-charter section header.
# AC2: prompt contains each acceptance test file — the test-folder files that
#      hold a SPEC's tag (#2508: design names none).
# AC3: prompt contains explicit 'MUST NOT weaken' prohibition.
# AC4: behavioral — when the mocked router modifies an acceptance test file,
#      build.scope.violation is emitted for it: the file is in the test folders,
#      which build may not change (#2508, ADR-030 §8).
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
    && mkdir -p tests/unit src \
    && printf 'assert "[BUCHRT-1] charter" 1 1\n' > tests/unit/build-acceptance-charter-test.sh \
    && printf 'assert "[BUCHRT-2] framing" 1 1\n' > tests/unit/build-prompt-framing-test.sh \
    && printf '# [BUCHRT-1] a tag outside the test folders\n' > src/notes.sh \
    && git add -A \
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
BUCHRT-1[code]: build prompt must include acceptance charter section
BUCHRT-2[code]: weakening acceptance test files is put back
WIRING: none
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
if grep -qF "## ACCEPTANCE TESTS" <<< "$captured_prompt"; then
    assert_pass "AC1: prompt contains acceptance-charter section header"
else
    assert_fail "AC1: prompt must contain '## ACCEPTANCE TESTS' header" \
        "header not found in prompt"
fi

# AC2: each acceptance test file, found by its tag, appears in the prompt.
if grep -qF "tests/unit/build-acceptance-charter-test.sh" <<< "$captured_prompt"; then
    assert_pass "AC2a: prompt contains first TESTFILES path"
else
    assert_fail "AC2a: prompt must contain 'tests/unit/build-acceptance-charter-test.sh'" \
        "path not found in prompt"
fi
if grep -qF "tests/unit/build-prompt-framing-test.sh" <<< "$captured_prompt"; then
    assert_pass "AC2b: prompt contains second TESTFILES path"
else
    assert_fail "AC2b: prompt must contain 'tests/unit/build-prompt-framing-test.sh'" \
        "path not found in prompt"
fi

# AC3: explicit MUST NOT weaken prohibition present.
if grep -qF "MUST NOT weaken" <<< "$captured_prompt"; then
    assert_pass "AC3: prompt contains 'MUST NOT weaken' prohibition"
else
    assert_fail "AC3: prompt must contain 'MUST NOT weaken'" \
        "prohibition phrase not found in prompt"
fi

# ─── AC4: scope enforcer catches modification of acceptance test file ─────────
# Re-set events file for clean capture.
: > "$ZBUILD_EVENTS_JSONL"

# The acceptance test file is in the test folders; the mocked router edits it
# to simulate the LLM "weakening" the test. The test-folder check must emit
# build.scope.violation for that path (it is tracked: the check uses git diff HEAD).
ACCEPTANCE_TEST_FILE="tests/unit/build-acceptance-charter-test.sh"

# Redefine route_to_model_loop to edit the acceptance test file (not in scope).
# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    # Simulate the LLM weakening the acceptance test (a test-folder edit).
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
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -c '"type"' || true)"

if [[ "$violation_count" -ge 1 ]]; then
    assert_pass "AC4: build.scope.violation emitted for acceptance test file"
else
    assert_fail "AC4: build.scope.violation must fire for an acceptance test edit" \
        "count=$violation_count in $ZBUILD_EVENTS_JSONL"
fi

# Also confirm build-summary.json records scope_violation=true, and the edit is put back.
summary_violation="$(jq -r '.scope_violation' "$SUMMARY_JSON" 2>/dev/null || echo 'null')"
if [[ "$summary_violation" == "true" ]]; then
    assert_pass "AC4: build-summary.json scope_violation=true"
else
    assert_fail "AC4: build-summary.json must have scope_violation=true" \
        "got scope_violation=$summary_violation"
fi
assert_eq "AC4: the weakened acceptance test is put back" 'assert "[BUCHRT-1] charter" 1 1' \
    "$(cat "$_CHARTER_REPO/$ACCEPTANCE_TEST_FILE")"

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

# ─── H3 (Copilot review; #2508): only test-folder files are surfaced ──────────
# A file outside the test folders that holds a SPEC's tag is not a test, so the
# build prompt never advertises it.
if declare -F _build_read_acceptance_testfiles >/dev/null 2>&1; then
    case "$tf_out" in
        *"src/notes.sh"*)
            assert_fail "H3: a tagged file outside the test folders leaked into output" "got: $tf_out" ;;
        *)
            assert_pass "H3: a tagged file outside the test folders is not a test file" ;;
    esac
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
