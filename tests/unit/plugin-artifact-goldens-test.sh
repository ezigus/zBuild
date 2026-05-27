#!/usr/bin/env bash
# Tests: golden fixtures for 5 plugin artifact outputs (issue #367).
# Verifies golden files exist and contain expected structural fields.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "plugin artifact goldens — 5 plugin output contracts (issue #367)"

GOLDEN_DIR="$REPO_ROOT/tests/golden"

# ─── Helpers ──────────────────────────────────────────────────────────────────

# assert_golden_exists <golden-name>
assert_golden_exists() {
    local name="$1"
    local golden_file="$GOLDEN_DIR/${name}.golden"
    if [[ -f "$golden_file" ]]; then
        assert_pass "golden file exists: ${name}.golden"
    else
        assert_fail "golden file exists: ${name}.golden" "missing: $golden_file"
    fi
}

# assert_golden_contains <golden-name> <expected-substring>
assert_golden_contains() {
    local name="$1"
    local needle="$2"
    local golden_file="$GOLDEN_DIR/${name}.golden"
    if [[ ! -f "$golden_file" ]]; then
        assert_fail "golden contains '${needle}' in ${name}" "golden file missing"
        return
    fi
    local content
    content="$(cat "$golden_file")"
    assert_contains "golden ${name} contains '${needle}'" "$content" "$needle"
}

# assert_golden_is_valid_json <golden-name>
assert_golden_is_valid_json() {
    local name="$1"
    local golden_file="$GOLDEN_DIR/${name}.golden"
    if [[ ! -f "$golden_file" ]]; then
        assert_fail "golden ${name} is valid JSON" "golden file missing"
        return
    fi
    if jq empty "$golden_file" >/dev/null 2>&1; then
        assert_pass "golden ${name} is valid JSON"
    else
        assert_fail "golden ${name} is valid JSON" "jq parse failed"
    fi
}

# ─── G1: plan-artifact ────────────────────────────────────────────────────────
# plugins/agent/plan produces state/artifacts/plan.json
# Required fields: schema_version=1, steps (non-empty array)
print_test_section "G1: plan-artifact.golden"
assert_golden_exists "plan-artifact"
assert_golden_is_valid_json "plan-artifact"
assert_golden_contains "plan-artifact" '"schema_version"'
assert_golden_contains "plan-artifact" '"steps"'

g1_content="$(cat "$GOLDEN_DIR/plan-artifact.golden" 2>/dev/null || echo '{}')"
g1_schema="$(printf '%s' "$g1_content" | jq -r '.schema_version' 2>/dev/null || echo '')"
if [[ "$g1_schema" == "1" ]]; then
    assert_pass "G1: plan-artifact schema_version == 1"
else
    assert_fail "G1: plan-artifact schema_version == 1" "got: $g1_schema"
fi

g1_steps_len="$(printf '%s' "$g1_content" | jq '.steps | length' 2>/dev/null || echo '0')"
if [[ "$g1_steps_len" -gt 0 ]] 2>/dev/null; then
    assert_pass "G1: plan-artifact steps array is non-empty"
else
    assert_fail "G1: plan-artifact steps array is non-empty" "length: $g1_steps_len"
fi

set +e
assert_golden "plan-artifact" "$g1_content"
g1_golden_rc=$?
set -e
if [[ $g1_golden_rc -eq 0 ]]; then
    assert_pass "G1: plan-artifact exact golden match"
else
    assert_fail "G1: plan-artifact exact golden match" "assert_golden returned $g1_golden_rc"
fi

# ─── G2: build-summary-artifact ───────────────────────────────────────────────
# plugins/agent/build produces state/artifacts/build-summary.json
# Required fields: schema_version=1, files_changed, lines_added, lines_removed,
#                  diff_patch_path, notes
print_test_section "G2: build-summary-artifact.golden"
assert_golden_exists "build-summary-artifact"
assert_golden_is_valid_json "build-summary-artifact"
assert_golden_contains "build-summary-artifact" '"schema_version"'
assert_golden_contains "build-summary-artifact" '"files_changed"'
assert_golden_contains "build-summary-artifact" '"lines_added"'
assert_golden_contains "build-summary-artifact" '"lines_removed"'
assert_golden_contains "build-summary-artifact" '"diff_patch_path"'
assert_golden_contains "build-summary-artifact" '"notes"'

g2_content="$(cat "$GOLDEN_DIR/build-summary-artifact.golden" 2>/dev/null || echo '{}')"
g2_schema="$(printf '%s' "$g2_content" | jq -r '.schema_version' 2>/dev/null || echo '')"
if [[ "$g2_schema" == "1" ]]; then
    assert_pass "G2: build-summary-artifact schema_version == 1"
else
    assert_fail "G2: build-summary-artifact schema_version == 1" "got: $g2_schema"
fi

g2_notes="$(printf '%s' "$g2_content" | jq -r '.notes' 2>/dev/null || echo '')"
if [[ "$g2_notes" == *"Diff written to artifact"* ]]; then
    assert_pass "G2: build-summary notes field mentions artifact"
else
    assert_fail "G2: build-summary notes field mentions artifact" "got: $g2_notes"
fi

set +e
assert_golden "build-summary-artifact" "$g2_content"
g2_golden_rc=$?
set -e
if [[ $g2_golden_rc -eq 0 ]]; then
    assert_pass "G2: build-summary-artifact exact golden match"
else
    assert_fail "G2: build-summary-artifact exact golden match" "assert_golden returned $g2_golden_rc"
fi

# ─── G3: review-artifact ──────────────────────────────────────────────────────
# plugins/agent/review produces state/artifacts/review.json
# Required fields: schema_version=1, verdict, confidence, issues, summary
print_test_section "G3: review-artifact.golden"
assert_golden_exists "review-artifact"
assert_golden_is_valid_json "review-artifact"
assert_golden_contains "review-artifact" '"schema_version"'
assert_golden_contains "review-artifact" '"verdict"'
assert_golden_contains "review-artifact" '"confidence"'
assert_golden_contains "review-artifact" '"issues"'
assert_golden_contains "review-artifact" '"summary"'

g3_content="$(cat "$GOLDEN_DIR/review-artifact.golden" 2>/dev/null || echo '{}')"
g3_schema="$(printf '%s' "$g3_content" | jq -r '.schema_version' 2>/dev/null || echo '')"
if [[ "$g3_schema" == "1" ]]; then
    assert_pass "G3: review-artifact schema_version == 1"
else
    assert_fail "G3: review-artifact schema_version == 1" "got: $g3_schema"
fi

g3_verdict="$(printf '%s' "$g3_content" | jq -r '.verdict' 2>/dev/null || echo '')"
valid_verdicts="approve request_changes block"
g3_valid=false
for vv in $valid_verdicts; do
    if [[ "$g3_verdict" == "$vv" ]]; then
        g3_valid=true
        break
    fi
done
if $g3_valid; then
    assert_pass "G3: review-artifact verdict is a valid value (${g3_verdict})"
else
    assert_fail "G3: review-artifact verdict is a valid value" "got: '$g3_verdict'; valid: $valid_verdicts"
fi

set +e
assert_golden "review-artifact" "$g3_content"
g3_golden_rc=$?
set -e
if [[ $g3_golden_rc -eq 0 ]]; then
    assert_pass "G3: review-artifact exact golden match"
else
    assert_fail "G3: review-artifact exact golden match" "assert_golden returned $g3_golden_rc"
fi

# ─── G4: pr-result-artifact ───────────────────────────────────────────────────
# plugins/tool/pr-open produces state/artifacts/pr-result.json
# Required fields: schema_version=1, status, pr_url, draft=true, branch, issue
print_test_section "G4: pr-result-artifact.golden"
assert_golden_exists "pr-result-artifact"
assert_golden_is_valid_json "pr-result-artifact"
assert_golden_contains "pr-result-artifact" '"schema_version"'
assert_golden_contains "pr-result-artifact" '"status"'
assert_golden_contains "pr-result-artifact" '"pr_url"'
assert_golden_contains "pr-result-artifact" '"draft"'
assert_golden_contains "pr-result-artifact" '"branch"'

g4_content="$(cat "$GOLDEN_DIR/pr-result-artifact.golden" 2>/dev/null || echo '{}')"
g4_schema="$(printf '%s' "$g4_content" | jq -r '.schema_version' 2>/dev/null || echo '')"
if [[ "$g4_schema" == "1" ]]; then
    assert_pass "G4: pr-result-artifact schema_version == 1"
else
    assert_fail "G4: pr-result-artifact schema_version == 1" "got: $g4_schema"
fi

g4_draft="$(printf '%s' "$g4_content" | jq -r '.draft' 2>/dev/null || echo '')"
if [[ "$g4_draft" == "true" ]]; then
    assert_pass "G4: pr-result-artifact draft == true (safety constraint)"
else
    assert_fail "G4: pr-result-artifact draft == true (safety constraint)" "got: $g4_draft"
fi

set +e
assert_golden "pr-result-artifact" "$g4_content"
g4_golden_rc=$?
set -e
if [[ $g4_golden_rc -eq 0 ]]; then
    assert_pass "G4: pr-result-artifact exact golden match"
else
    assert_fail "G4: pr-result-artifact exact golden match" "assert_golden returned $g4_golden_rc"
fi

# ─── G5: orch-sequential-capabilities ────────────────────────────────────────
# plugins/tool/orch-sequential orch_capabilities() output
# Required fields: backend == "sequential", capabilities array
print_test_section "G5: orch-sequential-capabilities.golden"
assert_golden_exists "orch-sequential-capabilities"
assert_golden_is_valid_json "orch-sequential-capabilities"
assert_golden_contains "orch-sequential-capabilities" '"backend"'
assert_golden_contains "orch-sequential-capabilities" '"capabilities"'
assert_golden_contains "orch-sequential-capabilities" '"sequential"'

g5_content="$(cat "$GOLDEN_DIR/orch-sequential-capabilities.golden" 2>/dev/null || echo '{}')"
g5_backend="$(printf '%s' "$g5_content" | jq -r '.backend' 2>/dev/null || echo '')"
if [[ "$g5_backend" == "sequential" ]]; then
    assert_pass "G5: orch-sequential-capabilities backend == sequential"
else
    assert_fail "G5: orch-sequential-capabilities backend == sequential" "got: $g5_backend"
fi

g5_caps_len="$(printf '%s' "$g5_content" | jq '.capabilities | length' 2>/dev/null || echo '0')"
if [[ "$g5_caps_len" -gt 0 ]] 2>/dev/null; then
    assert_pass "G5: orch-sequential-capabilities has non-empty capabilities array"
else
    assert_fail "G5: orch-sequential-capabilities has non-empty capabilities array" "length: $g5_caps_len"
fi

# Verify actual plugin output matches golden (source plugin to call orch_capabilities)
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/plugins/tool/orch-sequential/plugin.sh"
g5_live_output="$(orch_capabilities)"
set +e
assert_golden "orch-sequential-capabilities" "$g5_live_output"
g5_golden_rc=$?
set -e
if [[ $g5_golden_rc -eq 0 ]]; then
    assert_pass "G5: orch-sequential live orch_capabilities() matches golden"
else
    assert_fail "G5: orch-sequential live orch_capabilities() matches golden" \
        "assert_golden returned $g5_golden_rc; live output: $g5_live_output"
fi

print_test_results
exit $((FAIL > 0))
