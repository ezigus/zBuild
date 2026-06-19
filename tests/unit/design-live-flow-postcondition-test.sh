#!/usr/bin/env bash
# Tests: _design_stage_run_inner live-flow post-condition (issue #913 / ADR-031).
#
# Verifies that _design_stage_run_inner:
#   P1: SPEC-1[change]: + all unit TESTFILES → rc=1 (missing_live_flow_spec)
#   P2: SPEC-1[change]: + one tests/integration/ TESTFILE → rc=0 (accepted)
#   P3: SPEC-1[guard]: only + all unit TESTFILES → rc=0 (no change SPEC → no requirement)
#   P4: SPEC-1: (unclassified) + all unit TESTFILES → rc=0 (backward compatible)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: live-flow post-condition (#913)"
setup_test_env "design-live-flow-postcondition"

# ─── Shared mock setup ───────────────────────────────────────────────────────
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

route_to_model_loop() {
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

_bt='```'

# ─── P1: SPEC-1[change]: + all unit TESTFILES → rc=1 ────────────────────────
_setup_fixture p1
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(printf '# Design\n\n## Decision\nImpl.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[change]: new behavior\nTESTFILES:\ntests/unit/foo-test.sh\ntests/unit/bar-test.sh\n%s\n' \
    "$_bt" "$_bt" "$_bt" "$_bt")"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "[SPEC-4] P1: [change] SPEC + all-unit TESTFILES → rc=1" "1" "$rc"
if grep -q '"design.missing_live_flow_spec"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-4] P1: design.missing_live_flow_spec event emitted"
else
    assert_fail "[SPEC-4] P1: design.missing_live_flow_spec event not emitted" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── P2: SPEC-1[change]: + ≥1 integration TESTFILE → rc=0 ───────────────────
_setup_fixture p2
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(printf '# Design\n\n## Decision\nImpl.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[change]: new behavior\nTESTFILES:\ntests/unit/foo-test.sh\ntests/integration/bar-test.sh\n%s\n' \
    "$_bt" "$_bt" "$_bt" "$_bt")"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "[SPEC-5] P2: [change] SPEC + integration TESTFILE → rc=0" "0" "$rc"
if grep -q '"design.missing_live_flow_spec"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-5] P2: missing_live_flow_spec must NOT be emitted when integration TESTFILE present" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
else
    assert_pass "[SPEC-5] P2: design.missing_live_flow_spec correctly absent"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── P3: SPEC-1[guard]: only + all unit TESTFILES → rc=0 ─────────────────────
_setup_fixture p3
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(printf '# Design\n\n## Decision\nImpl.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[guard]: invariant\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' \
    "$_bt" "$_bt" "$_bt" "$_bt")"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "[SPEC-5] P3: guard-only SPECs + unit TESTFILES → rc=0" "0" "$rc"
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── P4: unclassified SPEC-1: + all unit TESTFILES → rc=0 (backward compat) ──
_setup_fixture p4
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(printf '# Design\n\n## Decision\nImpl.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1: some behavior\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' \
    "$_bt" "$_bt" "$_bt" "$_bt")"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR"
rc=$?
set -e
assert_eq "[SPEC-5] P4: unclassified SPEC + unit TESTFILES → rc=0 (backward compat)" "0" "$rc"
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

cleanup_test_env
print_test_results
exit $((FAIL > 0))
