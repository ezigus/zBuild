#!/usr/bin/env bash
# Tests: design plugin acceptance-block integration (issue #865 / ADR-031).
#
# Verifies that _design_stage_run_inner:
#   (a) accepts a design.md with both a ```scope and ```acceptance block (rc=0)
#   (b) rejects a design.md that has a scope block but no acceptance block (rc=1)
#   (c) leaves existing test files untouched (stub-writer removed; issue #1477)
#   (d) acceptance-block grammar helpers work correctly
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

# ─── T1: design.md with scope + acceptance → rc=0, design.md written ─────────
# The stub-writer was removed (issue #1477); only rc=0 and artifact presence
# are asserted here. No stubs are created and no event is emitted.
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
   grep -q '"reason":"missing_acceptance_block"' <<< "$(grep '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL")"; then
    assert_pass "T2: plugin.run.error reason=missing_acceptance_block emitted"
else
    assert_fail "T2: missing_acceptance_block error not emitted" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── T3: existing test file is NOT overwritten (trivially true, no stub-writer)
# The stub-writer is removed (issue #1477). The plugin no longer writes any
# testfile. Pre-existing testfiles must remain untouched: verify rc=0 and
# content preserved.
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
if grep -q "existing content" <<< "$existing_content"; then
    assert_pass "T3: existing test file content preserved (not overwritten)"
else
    assert_fail "T3: existing test file was overwritten" \
        "content: $existing_content"
fi
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

# ─── T6: acceptance_spec_is_guard works for [guard]-classified SPEC ──────────
work_file_t6="$TEST_TEMP_DIR/tc6_design.md"
_t6_bt='```'
printf '# Design\n\n%sacceptance\nSPEC-1[guard]: invariant\nSPEC-2[change]: new behavior\nTESTFILES:\ntests/unit/foo-test.sh\ntests/integration/bar-test.sh\n%s\n' \
    "$_t6_bt" "$_t6_bt" > "$work_file_t6"
set +e
acceptance_spec_is_guard "$work_file_t6" "SPEC-1"; t6_guard_rc=$?
acceptance_spec_is_guard "$work_file_t6" "SPEC-2"; t6_change_rc=$?
set -e
assert_eq "T6: [guard] SPEC recognized (rc=0)" "0" "$t6_guard_rc"
assert_eq "T6: [change] SPEC not a guard (rc=1)" "1" "$t6_change_rc"

# ─── T7: acceptance_list_spec_ids returns bare ids from classified lines ──────
work_file_t7="$TEST_TEMP_DIR/tc7_design.md"
_t7_bt='```'
printf '# Design\n\n%sacceptance\nSPEC-1[change]: first\nSPEC-2[guard]: second\nSPEC-3: unclassified\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' \
    "$_t7_bt" "$_t7_bt" > "$work_file_t7"
set +e
t7_out="$(acceptance_list_spec_ids "$work_file_t7")"; t7_rc=$?
set -e
assert_eq "T7: acceptance_list_spec_ids returns 0" "0" "$t7_rc"
assert_eq "T7: SPEC-1 listed (bare, no classifier)" "1" "$(echo "$t7_out" | grep -c '^SPEC-1$')"
assert_eq "T7: SPEC-2 listed (bare, no classifier)" "1" "$(echo "$t7_out" | grep -c '^SPEC-2$')"
assert_eq "T7: SPEC-3 listed (bare, unclassified)" "1" "$(echo "$t7_out" | grep -c '^SPEC-3$')"

# ─── T8: acceptance_spec_is_guard returns correct values for each type ────────
work_file_t8="$TEST_TEMP_DIR/tc8_design.md"
_t8_bt='```'
printf '# Design\n\n%sacceptance\nSPEC-1[guard]: g\nSPEC-2[change]: c\nSPEC-3: u\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' \
    "$_t8_bt" "$_t8_bt" > "$work_file_t8"
set +e
acceptance_spec_is_guard "$work_file_t8" "SPEC-1"; t8_g=$?
acceptance_spec_is_guard "$work_file_t8" "SPEC-2"; t8_c=$?
acceptance_spec_is_guard "$work_file_t8" "SPEC-3"; t8_u=$?
set -e
assert_eq "T8: [guard] is guard (rc=0)" "0" "$t8_g"
assert_eq "T8: [change] is not guard (rc=1)" "1" "$t8_c"
assert_eq "T8: unclassified is not guard (rc=1)" "1" "$t8_u"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
