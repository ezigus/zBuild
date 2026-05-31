#!/usr/bin/env bash
# Tests: render_test_assessment_md renderer (#567)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "render_test_assessment_md (#567)"
setup_test_env "render-test-assessment"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── R1: renderer is registered ──────────────────────────────────────────────
fn="$(artifact_renderer_for test_assessment 2>/dev/null || true)"
if [[ "$fn" == "render_test_assessment_md" ]]; then
    assert_pass "R1 test_assessment renderer registered"
else
    assert_fail "R1 test_assessment renderer registered" "got '$fn'"
fi

# ─── R2: empty input → placeholder ───────────────────────────────────────────
out="$(render_test_assessment_md "")"
assert_contains "R2 empty input → placeholder" "$out" "_empty"

# ─── R3: pass verdict renders heading ────────────────────────────────────────
input='{"schema_version":1,"verdict":"pass","summary":"all green","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"files=2 add=10 del=2","failure_summary_md":"All tests passed.","iter":1}'
out="$(render_test_assessment_md "$input")"
assert_contains "R3 pass heading" "$out" "# Test Assessment"
assert_contains "R3 pass verdict line" "$out" "pass"
assert_contains "R3 failure_summary_md verbatim" "$out" "All tests passed."

# ─── R4: fail with required_changes renders bullets ──────────────────────────
input='{"schema_version":1,"verdict":"fail","summary":"3 tests failing","diagnosis":"missing import","required_changes":["add import x","fix typo"],"agrees_with_build_complete":false,"branch_numstat":"files=1 add=5 del=0","failure_summary_md":"## Failures\n- AuthTest broke","iter":2}'
out="$(render_test_assessment_md "$input")"
assert_contains "R4 fail verdict" "$out" "fail"
assert_contains "R4 required_changes bullet 1" "$out" "add import x"
assert_contains "R4 required_changes bullet 2" "$out" "fix typo"
assert_contains "R4 failure_summary_md verbatim block" "$out" "AuthTest broke"

# ─── R5: malformed JSON → fenced raw passthrough ─────────────────────────────
out="$(render_test_assessment_md '{not json')"
assert_contains "R5 malformed JSON preserved" "$out" "{not json"

# ─── R6: prose around JSON → ── llm comment ── trailing block ────────────────
input='Here is the assessment.

{"schema_version":1,"verdict":"inconclusive","summary":"low signal","diagnosis":"","required_changes":[],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"Inconclusive.","iter":3}

Let me know if you need more.'
out="$(render_test_assessment_md "$input")"
assert_contains "R6 prose surfaces as llm comment" "$out" "── llm comment ──"
assert_contains "R6 renders inconclusive verdict" "$out" "inconclusive"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
