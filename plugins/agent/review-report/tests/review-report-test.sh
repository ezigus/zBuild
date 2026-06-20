#!/usr/bin/env bash
# Tests: plugins/agent/review-report — multi-lens review report plugin (issue #972)
# Covers: SPEC-1 through SPEC-5 (CHANGE-behavior specs; fail at baseline, pass here).
# SPEC-6 lives in tests/unit/docs-adr-013-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: review-report (issue #972)"
setup_test_env "plugin-review-report"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="review-report-test-$$"

mkdir -p "$TEST_TEMP_DIR/bin" "$ZBUILD_EVENTS_DIR"

# ─── Stub `claude` CLI so route_to_model produces deterministic output ────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'CLAUDE_STUB'
#!/usr/bin/env bash
# Stub: emit a valid review-report JSON envelope
printf '{"schema_version":1,"merge_readiness":"advisory","lenses":[{"name":"correctness","findings":["No issues found"],"score":8},{"name":"security","findings":["No issues found"],"score":9},{"name":"test-coverage","findings":["Good coverage"],"score":7},{"name":"plan-conformance","findings":["Matches plan"],"score":8}],"summary":"The changes look solid. No critical findings across all lenses."}\n'
CLAUDE_STUB
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# ─── Source plugin ────────────────────────────────────────────────────────────
# shellcheck source=../../../../plugins/agent/review-report/plugin.sh
source "$REPO_ROOT/plugins/agent/review-report/plugin.sh"

# ─── Fixtures ─────────────────────────────────────────────────────────────────
SCOPE_MANIFEST="$TEST_TEMP_DIR/scope-manifest.md"
ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ARTIFACT_DIR" "$STATE_DIR"

cat > "$SCOPE_MANIFEST" <<'EOF'
# Scope Manifest
## Allowed paths
- tests/
EOF

cat > "$ARTIFACT_DIR/diff.patch" <<'EOF'
--- a/tests/foo.sh
+++ b/tests/foo.sh
@@ -1 +1,2 @@
+echo "hello"
EOF

cat > "$ARTIFACT_DIR/test-results.json" <<'EOF'
{"verdict":"pass","passed":5,"failed":0}
EOF

# ─── [SPEC-1]: review-report is in _ZBUILD_CANONICAL_STAGES (CHANGE) ─────────
# At baseline, review-report is absent from the array; after this change it is
# present. Loading template.sh populates _ZBUILD_CANONICAL_STAGES.
TEMPLATE_SH="$REPO_ROOT/core/pipeline/template.sh"
source "$TEMPLATE_SH"
spec1_found=0
for _cs in "${_ZBUILD_CANONICAL_STAGES[@]}"; do
    [[ "$_cs" == "review-report" ]] && spec1_found=1 && break
done
assert_eq "[SPEC-1] review-report in _ZBUILD_CANONICAL_STAGES" "1" "$spec1_found"

# ─── [SPEC-2]: simple.yaml template loads successfully (CHANGE) ───────────────
# At baseline, config/templates/simple.yaml does not exist; after this change
# load_template succeeds.
SIMPLE_TPL="$REPO_ROOT/config/templates/simple.yaml"
set +e
load_template "$SIMPLE_TPL" 2>/dev/null
spec2_rc=$?
set -e
assert_eq "[SPEC-2] simple.yaml loads with load_template (rc=0)" "0" "$spec2_rc"

# ─── T1: init hook sets ZBUILD_PLUGIN=review-report ──────────────────────────
review_report_init
assert_eq "T1: review_report_init sets ZBUILD_PLUGIN=review-report" \
    "review-report" "${ZBUILD_PLUGIN:-}"

# ─── T2: run emits report.json with required fields ──────────────────────────
_rr_run_inner \
    "$SCOPE_MANIFEST" \
    "" \
    "$ARTIFACT_DIR/diff.patch" \
    "$ARTIFACT_DIR/test-results.json" \
    "$ARTIFACT_DIR/report.json" \
    "$ARTIFACT_DIR/report.md" \
    ""

assert_pass "T2: _rr_run_inner exits 0"

# Verify report.json was written
if [[ -s "$ARTIFACT_DIR/report.json" ]]; then
    assert_pass "T2: report.json exists and is non-empty"
else
    assert_fail "T2: report.json exists and is non-empty" "file missing or empty"
fi

# Verify required fields
for field in schema_version merge_readiness lenses summary; do
    field_present="$(jq -r --arg f "$field" 'has($f)' "$ARTIFACT_DIR/report.json" 2>/dev/null || echo "false")"
    assert_eq "T2: report.json has field '$field'" "true" "$field_present"
done

# ─── [SPEC-3]: report.json never contains 'block' or 'coerce' (CHANGE) ───────
set +e
grep -q '"block"' "$ARTIFACT_DIR/report.json" 2>/dev/null
spec3_block_rc=$?
grep -q '"coerce"' "$ARTIFACT_DIR/report.json" 2>/dev/null
spec3_coerce_rc=$?
set -e
assert_eq "[SPEC-3] report.json does not contain the string 'block'" "1" "$spec3_block_rc"
assert_eq "[SPEC-3] report.json does not contain the string 'coerce'" "1" "$spec3_coerce_rc"

# ─── T4: report.md sibling artifact is written ───────────────────────────────
if [[ -s "$ARTIFACT_DIR/report.md" ]]; then
    assert_pass "T4: report.md sibling artifact written"
else
    assert_fail "T4: report.md sibling artifact written" "file missing or empty"
fi

# ─── [SPEC-4]: merge_readiness is always one of three valid values (CHANGE) ──
mr_val="$(jq -r '.merge_readiness' "$ARTIFACT_DIR/report.json" 2>/dev/null || echo "")"
case "$mr_val" in
    ready|advisory|needs_attention)
        assert_pass "[SPEC-4] merge_readiness='$mr_val' is a valid value"
        ;;
    *)
        assert_fail "[SPEC-4] merge_readiness is a valid value" \
            "got: '$mr_val' (expected ready|advisory|needs_attention)"
        ;;
esac

# ─── [SPEC-4] extra: _rr_validate_readiness sanitizes unknown values ──────────
sanitized="$(_rr_validate_readiness "totally_unexpected_value")"
assert_eq "[SPEC-4] _rr_validate_readiness defaults unknown to advisory" \
    "advisory" "$sanitized"

sanitized_ready="$(_rr_validate_readiness "ready")"
assert_eq "[SPEC-4] _rr_validate_readiness passes through 'ready'" \
    "ready" "$sanitized_ready"

sanitized_na="$(_rr_validate_readiness "needs_attention")"
assert_eq "[SPEC-4] _rr_validate_readiness passes through 'needs_attention'" \
    "needs_attention" "$sanitized_na"

# ─── [SPEC-5]: plugin exits 0 when gh is absent (fail-soft PR comment) ────────
# Stub gh to exit non-zero; the plugin must still return 0 and write report.json.
ARTIFACT_DIR2="$TEST_TEMP_DIR/artifacts2"
mkdir -p "$ARTIFACT_DIR2"

cat > "$TEST_TEMP_DIR/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
exit 1
GH_STUB
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_PR_NUMBER="42"

set +e
_rr_run_inner \
    "$SCOPE_MANIFEST" \
    "" \
    "$ARTIFACT_DIR/diff.patch" \
    "$ARTIFACT_DIR/test-results.json" \
    "$ARTIFACT_DIR2/report.json" \
    "$ARTIFACT_DIR2/report.md" \
    ""
spec5_rc=$?
set -e
unset ZBUILD_PR_NUMBER

assert_eq "[SPEC-5] plugin exits 0 even when gh is absent (fail-soft)" "0" "$spec5_rc"

if [[ -s "$ARTIFACT_DIR2/report.json" ]]; then
    assert_pass "[SPEC-5] report.json still written when gh is absent"
else
    assert_fail "[SPEC-5] report.json still written when gh is absent" "file missing"
fi

# ─── T6: finalize hook ────────────────────────────────────────────────────────
review_report_finalize
assert_pass "T6: review_report_finalize exits 0"

# ─────────────────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
