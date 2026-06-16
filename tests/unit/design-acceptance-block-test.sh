#!/usr/bin/env bash
# Tests: design plugin acceptance-block integration (issue #865 / ADR-031).
#
# Verifies that _design_stage_run_inner:
#   (a) accepts a design.md with both a ```scope and ```acceptance block (rc=0)
#   (b) writes named test-file stubs to disk when TESTFILES are listed
#   (c) each created stub exits non-zero when executed (red-first)
#   (d) rejects a design.md that has a scope block but no acceptance block (rc=1)
#   (e) leaves existing test files untouched (does not regress a passing test)
#   (f) emits design.acceptance_tests.written with the correct count
#   (g) rejects unsafe (absolute / "..") TESTFILES paths — no write-scope escape
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: acceptance-block post-condition + test-file stubs (#865)"
setup_test_env "design-acceptance-block"

# ─── Shared mock setup ───────────────────────────────────────────────────────
# Source design plugin first so real dependencies load, then override mocks.
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# MOCK_DESIGN_BODY drives what route_to_model_loop writes at MOCK_DESIGN_WRITE_PATH.
route_to_model_loop() {
    local _prompt_file="$2"
    local _body="${MOCK_DESIGN_BODY:-}"
    if [[ -z "$_body" ]]; then
        local _bt='```'
        _body="$(printf '# Design\n\n%sscope\nfoo.sh\n%s\n' "$_bt" "$_bt")"
    fi
    if [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]]; then
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '%s' "$_body" > "$MOCK_DESIGN_WRITE_PATH"
    fi
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write()          { local dest="$1"; cat - > "$dest"; }

_setup_fixture() {
    local test_id="$1"
    FIXTURE_DIR="$TEST_TEMP_DIR/$test_id"
    rm -rf "$FIXTURE_DIR"
    mkdir -p "$FIXTURE_DIR"
    git -C "$FIXTURE_DIR" init --quiet >/dev/null 2>&1
    git -C "$FIXTURE_DIR" config user.email 'test@example.com' >/dev/null 2>&1
    git -C "$FIXTURE_DIR" config user.name  'test' >/dev/null 2>&1
    local state_dir="$FIXTURE_DIR/state"
    ARTIFACT_DIR="$state_dir/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    SCOPE_MANIFEST="$state_dir/scope-manifest.md"
    PLAN_JSON="$ARTIFACT_DIR/plan.json"
    OUTPUT_MD="$ARTIFACT_DIR/design.md"
    printf 'scope: all\n' > "$SCOPE_MANIFEST"
    cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    export ZBUILD_REPO_ROOT="$FIXTURE_DIR"
    export ZBUILD_EVENTS_JSONL="$state_dir/events.jsonl"
    export ZBUILD_EVENTS_DIR="$state_dir"
    : > "$ZBUILD_EVENTS_JSONL"
}

# Helper: build a minimal valid design.md body with both scope + acceptance blocks.
_make_design_body_with_acceptance() {
    local tf1="${1:-tests/unit/stub-a-test.sh}"
    local tf2="${2:-tests/unit/stub-b-test.sh}"
    local _bt='```'
    printf '# Design\n\n## Decision\nImplement per plan.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC: foo works correctly\nSPEC: bar does its thing\nTESTFILES:\n%s\n%s\n%s\n' \
        "$_bt" "$_bt" "$_bt" "$tf1" "$tf2" "$_bt"
}

# ─── T1: design.md with scope + acceptance → rc=0, stubs written ─────────────
_setup_fixture t1
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(_make_design_body_with_acceptance 'tests/unit/stub-a-test.sh' 'tests/unit/stub-b-test.sh')"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "T1: design with acceptance block returns rc=0" "0" "$rc"
[[ -f "$OUTPUT_MD" ]] \
    && assert_pass "T1: design.md written at declared path" \
    || assert_fail "T1: design.md missing"

stub_a="$FIXTURE_DIR/tests/unit/stub-a-test.sh"
stub_b="$FIXTURE_DIR/tests/unit/stub-b-test.sh"
[[ -f "$stub_a" ]] \
    && assert_pass "T1: stub-a-test.sh created" \
    || assert_fail "T1: stub-a-test.sh not created"
[[ -f "$stub_b" ]] \
    && assert_pass "T1: stub-b-test.sh created" \
    || assert_fail "T1: stub-b-test.sh not created"

# Each stub must exit non-zero (red-first contract).
set +e
bash "$stub_a" >/dev/null 2>&1; stub_a_rc=$?
bash "$stub_b" >/dev/null 2>&1; stub_b_rc=$?
set -e
[[ $stub_a_rc -ne 0 ]] \
    && assert_pass "T1: stub-a exits non-zero (red-first)" \
    || assert_fail "T1: stub-a should exit non-zero but exited 0"
[[ $stub_b_rc -ne 0 ]] \
    && assert_pass "T1: stub-b exits non-zero (red-first)" \
    || assert_fail "T1: stub-b should exit non-zero but exited 0"

# design.acceptance_tests.written event with count=2
if grep -q '"design.acceptance_tests.written"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    if grep '"design.acceptance_tests.written"' "$ZBUILD_EVENTS_JSONL" | grep -q '"count":"2"'; then
        assert_pass "T1: design.acceptance_tests.written count=2"
    else
        assert_fail "T1: design.acceptance_tests.written has wrong count" \
            "events: $(cat "$ZBUILD_EVENTS_JSONL")"
    fi
else
    assert_fail "T1: design.acceptance_tests.written event not emitted" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── T2: design.md with scope but NO acceptance block → rc=1 ─────────────────
_setup_fixture t2
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
local_bt='```'
MOCK_DESIGN_BODY="$(printf '# Design\n\n%sscope\nfoo.sh\n%s\n' "$local_bt" "$local_bt")"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "T2: missing acceptance block returns rc=1" "1" "$rc"
if grep -q '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null && \
   grep '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL" | grep -q '"reason":"missing_acceptance_block"'; then
    assert_pass "T2: plugin.run.error reason=missing_acceptance_block emitted"
else
    assert_fail "T2: missing_acceptance_block error not emitted" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── T3: existing test file is NOT overwritten ───────────────────────────────
_setup_fixture t3
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(_make_design_body_with_acceptance 'tests/unit/existing-test.sh' 'tests/unit/new-test.sh')"
# Pre-create a "passing" test file with sentinel content.
mkdir -p "$FIXTURE_DIR/tests/unit"
printf '#!/usr/bin/env bash\necho "existing content"\n' > "$FIXTURE_DIR/tests/unit/existing-test.sh"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "T3: existing file scenario returns rc=0" "0" "$rc"
existing_content="$(cat "$FIXTURE_DIR/tests/unit/existing-test.sh")"
if echo "$existing_content" | grep -q "existing content"; then
    assert_pass "T3: existing test file content preserved (not overwritten)"
else
    assert_fail "T3: existing test file was overwritten" \
        "content: $existing_content"
fi
[[ -f "$FIXTURE_DIR/tests/unit/new-test.sh" ]] \
    && assert_pass "T3: new-test.sh stub created alongside preserved existing" \
    || assert_fail "T3: new-test.sh stub not created"

# count=1 (only the new stub was written, not the pre-existing one)
if grep '"design.acceptance_tests.written"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -q '"count":"1"'; then
    assert_pass "T3: acceptance_tests.written count=1 (skipped pre-existing)"
else
    assert_fail "T3: wrong count for acceptance_tests.written" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── T5 (#865 review): unsafe TESTFILES paths are rejected, never written ────
# The acceptance block is an LLM-produced artifact; absolute paths and ".."
# components must not let a stub escape ZBUILD_REPO_ROOT (ADR-031: TESTFILES
# grants no write-scope). Only the safe sibling path may be written.
_setup_fixture t5
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
_t5_bt='```'
_t5_abs="$TEST_TEMP_DIR/zbuild-t5-escape-test.sh"
rm -f "$_t5_abs"
MOCK_DESIGN_BODY="$(printf '# Design\n\n## Decision\nd.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC: safe\nTESTFILES:\n../zbuild-t5-escape-test.sh\n%s\ntests/unit/safe-stub-test.sh\n%s\n' \
    "$_t5_bt" "$_t5_bt" "$_t5_bt" "$_t5_abs" "$_t5_bt")"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "T5: mixed safe/unsafe TESTFILES returns rc=0" "0" "$rc"
[[ -f "$FIXTURE_DIR/tests/unit/safe-stub-test.sh" ]] \
    && assert_pass "T5: safe TESTFILES path written" \
    || assert_fail "T5: safe path should have been written"
[[ ! -e "$FIXTURE_DIR/../zbuild-t5-escape-test.sh" ]] \
    && assert_pass "T5: parent-escape (..) path not written outside repo root" \
    || assert_fail "T5: parent-escape path escaped repo root"
[[ ! -e "$_t5_abs" ]] \
    && assert_pass "T5: absolute path not written" \
    || assert_fail "T5: absolute path was written outside repo root"
# Only the safe stub counts toward the written total.
if grep '"design.acceptance_tests.written"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -q '"count":"1"'; then
    assert_pass "T5: acceptance_tests.written count=1 (unsafe paths excluded)"
else
    assert_fail "T5: wrong count after rejecting unsafe paths" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
rm -f "$_t5_abs" "$FIXTURE_DIR/../zbuild-t5-escape-test.sh"
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── T4: extract_acceptance_block returns 0 on a well-formed design.md ───────
work_file="$TEST_TEMP_DIR/tc4_design.md"
_bt='```'
printf '# Design\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC: it works\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' \
    "$_bt" "$_bt" "$_bt" "$_bt" > "$work_file"
set +e
extract_acceptance_block "$work_file" >/dev/null 2>&1
ab_rc=$?
set -e
assert_eq "T4: extract_acceptance_block returns 0 on well-formed design.md" "0" "$ab_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
