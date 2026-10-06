#!/usr/bin/env bash
# Tests: design plugin acceptance-block integration (issue #865 / ADR-031).
#
# Verifies that _design_stage_run_inner:
#   (a) accepts a design.md with both a ```scope and ```acceptance block (rc=0)
#   (b) rejects a design.md that has a scope block but no acceptance block (rc=1)
#   (c) leaves existing test files untouched (stub-writer removed; issue #1477)
#   (d) acceptance-block grammar helpers work correctly
#   (e) the prompt explains the three requirement statuses (#2304, ADR-069)
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
set +e
assert_eq "T1: design with acceptance block returns rc=0" "0" "$rc"
[[ -f "$OUTPUT_MD" ]] \
    && assert_pass "T1: design.md written at declared path" \
    || assert_fail "T1: design.md missing"
# Stub-writer removed (#1477): no executable test file may be created in the
# target tree. This assertion is load-bearing for WIRING reachability —
# reverting plugins/agent/design/plugin.sh to baseline (stub-writer present)
# would create stub-a-test.sh, flipping this from pass to fail.
if [[ ! -f "$FIXTURE_DIR/tests/unit/stub-a-test.sh" ]]; then
    assert_pass "[SPEC-3] design plugin wrote no stub file into target tree"
else
    assert_fail "[SPEC-3] design plugin must not write stub files into target tree" \
        "found unexpected stub: $FIXTURE_DIR/tests/unit/stub-a-test.sh"
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
set +e
assert_eq "T2: missing acceptance block returns rc=1" "1" "$rc"
if grep -q '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null && \
   grep -q '"reason":"missing_acceptance_block"' <<< "$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL")"; then
    assert_pass "T2: plugin.result reason=missing_acceptance_block emitted"
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
set +e
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
set +e
assert_eq "T4: extract_acceptance_block returns 0 on well-formed design.md" "0" "$ab_rc"

# ─── T6 (#2304, ADR-069 §1/§2): the prompt explains the three statuses ──────
# Design is told, in plain words, what each status means and how to name the
# evidence for an already-done requirement. The old tags are not offered.
_t6_prompt="$(cat "$TEST_TEMP_DIR/t1/state/artifacts/design-prompt.txt" 2>/dev/null)"
assert_contains "T6: the prompt offers SPEC-n[code]: for work that needs code" "$_t6_prompt" 'SPEC-n[code]:` — it needs code'
assert_contains "T6: [code] keeps the fail-before, pass-after rule" "$_t6_prompt" \
    "Its test must fail on the code as it is before your change, and pass after it"
assert_contains "T6: the prompt offers SPEC-n[no-code]: for work that changes no behaviour" "$_t6_prompt" \
    'SPEC-n[no-code]:` — it needs work that changes no behaviour'
assert_contains "T6: [no-code] need not fail before" "$_t6_prompt" "it need not fail before"
assert_contains "T6: the prompt offers SPEC-n[done]: for what the code already does" "$_t6_prompt" \
    'SPEC-n[done]:` — the code already does it'
assert_contains "T6: the evidence syntax is shown" "$_t6_prompt" "after \` evidence: \`"
assert_contains "T6: the example block carries a [done] line with evidence" "$_t6_prompt" \
    "SPEC-3[done]: <something the code already does> evidence: scripts/x.sh:42"
for _old in '[guard]' '[change]'; do
    if grep -qF -- "$_old" <<< "$_t6_prompt"; then
        assert_fail "T6: the prompt no longer offers $_old" "found in design-prompt.txt"
    else
        assert_pass "T6: the prompt no longer offers $_old"
    fi
done

# ─── T7: acceptance_list_spec_ids returns bare ids from classified lines ──────
work_file_t7="$TEST_TEMP_DIR/tc7_design.md"
_t7_bt='```'
printf '# Design\n\n%sacceptance\nSPEC-1[code]: first\nSPEC-2[done]: second evidence: foo.sh\nSPEC-3: no status\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' \
    "$_t7_bt" "$_t7_bt" > "$work_file_t7"
set +e
t7_out="$(acceptance_list_spec_ids "$work_file_t7")"; t7_rc=$?
set +e
assert_eq "T7: acceptance_list_spec_ids returns 0" "0" "$t7_rc"
assert_eq "T7: SPEC-1 listed (bare, no classifier)" "1" "$(echo "$t7_out" | grep -c '^SPEC-1$')"
assert_eq "T7: SPEC-2 listed (bare, no classifier)" "1" "$(echo "$t7_out" | grep -c '^SPEC-2$')"
assert_eq "T7: SPEC-3 listed (bare, unclassified)" "1" "$(echo "$t7_out" | grep -c '^SPEC-3$')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
