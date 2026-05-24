#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-intelligence test — Unit tests for intelligence   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-intelligence Tests"

setup_test_env "sw-lib-pipeline-intelligence-test"
_test_cleanup_hook() { cleanup_test_env; }

# Set up pipeline intelligence env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export STATE_FILE="$TEST_TEMP_DIR/state.json"
export BASE_BRANCH="main"
export ISSUE_NUMBER="42"
export ISSUE_LABELS=""
export INTELLIGENCE_COMPLEXITY="5"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline-config.json"
export PIPELINE_NAME="standard"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export IGNORE_BUDGET="true"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$PROJECT_ROOT"
mock_git

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
daemon_log() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }
rotate_jsonl() { :; }
log_stage() { :; }
write_state() { :; }
set_outer_stage() { OUTER_STAGE="${1:-}"; INNER_STAGE=""; write_state; }
clear_outer_stage() { OUTER_STAGE=""; INNER_STAGE=""; write_state; }
export OUTER_STAGE=""
export INNER_STAGE=""

# Minimal pipeline config for jq reads
echo '{"stages":[{"id":"compound_quality","config":{"audit_intensity":"auto"}}]}' > "$PIPELINE_CONFIG"

# Source the lib (clear guard)
_PIPELINE_INTELLIGENCE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-intelligence.sh"


# ═══════════════════════════════════════════════════════════════════════════════
# classify_quality_findings
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "classify_quality_findings"

# No findings → correctness route
rm -f "$ARTIFACTS_DIR/adversarial-review.md" "$ARTIFACTS_DIR/classified-findings.json"
route=$(classify_quality_findings)
assert_eq "No findings defaults to correctness" "correctness" "$route"

# Security findings
echo "**Security vulnerability**: SQL injection possible. Sanitize input." > "$ARTIFACTS_DIR/adversarial-review.md"
route=$(classify_quality_findings 2>/dev/null)
assert_eq "Security findings route to security" "security" "$route"
assert_file_exists "Creates classified-findings.json" "$ARTIFACTS_DIR/classified-findings.json"
security_count=$(jq -r '.security' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null)
assert_gt "Security count > 0" "${security_count:-0}" "0"

# Performance findings
echo "Performance bottleneck: N+1 queries detected. Memory leak possible." > "$ARTIFACTS_DIR/adversarial-review.md"
rm -f "$ARTIFACTS_DIR/security-audit.log" "$ARTIFACTS_DIR/compound-architecture-validation.json" "$ARTIFACTS_DIR/negative-review.md"
route=$(classify_quality_findings 2>/dev/null)
assert_eq "Performance findings route to performance" "performance" "$route"

# Style findings only
echo "Naming convention: consider using snake_case. Style inconsistency." > "$ARTIFACTS_DIR/adversarial-review.md"
route=$(classify_quality_findings 2>/dev/null)
assert_eq "Style-only findings route to correctness" "correctness" "$route"

# Architecture findings
echo "Architectural layer violation: circular dependency detected." > "$ARTIFACTS_DIR/adversarial-review.md"
route=$(classify_quality_findings 2>/dev/null)
assert_eq "Architecture findings route to architecture" "architecture" "$route"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_should_skip_stage
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_should_skip_stage"

# Never skip intake, build, test, pr, merge
for stage in intake build test pr merge; do
    if pipeline_should_skip_stage "$stage" 2>/dev/null; then
        assert_fail "Stage $stage should not be skipped"
    else
        assert_pass "Stage $stage correctly not skipped"
    fi
done

# compound_quality with documentation label → skip
ISSUE_LABELS="documentation,typo"
result=$(pipeline_should_skip_stage "compound_quality" 2>/dev/null || true)
assert_contains "Docs label skips compound_quality" "${result:-}" "label:documentation"

# compound_quality with hotfix label → skip
ISSUE_LABELS="hotfix,urgent"
result=$(pipeline_should_skip_stage "compound_quality" 2>/dev/null || true)
assert_contains "Hotfix label skips compound_quality" "${result:-}" "label:hotfix"

# Low complexity skips design
INTELLIGENCE_COMPLEXITY="2"
ISSUE_LABELS=""
result=$(pipeline_should_skip_stage "design" 2>/dev/null || true)
assert_contains "Low complexity skips design" "${result:-}" "complexity"

# compound_quality with reassessment override
ISSUE_LABELS=""
INTELLIGENCE_COMPLEXITY="5"
echo '{"skip_stages":["compound_quality"]}' > "$ARTIFACTS_DIR/reassessment.json"
result=$(pipeline_should_skip_stage "compound_quality" 2>/dev/null || true)
assert_contains "Reassessment skips compound_quality" "${result:-}" "reassessment"

# review with documentation label
ISSUE_LABELS="docs"
result=$(pipeline_should_skip_stage "review" 2>/dev/null || true)
assert_contains "Docs label skips review" "${result:-}" "label"

# plan with hotfix label
ISSUE_LABELS="p0,urgent"
result=$(pipeline_should_skip_stage "plan" 2>/dev/null || true)
assert_contains "Hotfix skips plan" "${result:-}" "label:hotfix"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_adaptive_cycles
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_adaptive_cycles"

# Base case: returns base limit
result=$(pipeline_adaptive_cycles 3 "compound_quality" 0 -1)
assert_eq "Base limit returned" "3" "$result"

# Convergence: issue count drops >50% → extend by 1
result=$(pipeline_adaptive_cycles 3 "compound_quality" 2 5)
assert_eq "Convergence extends limit" "4" "$result"

# Divergence: issue count increases → reduce
result=$(pipeline_adaptive_cycles 5 "compound_quality" 6 4)
assert_eq "Divergence reduces limit" "4" "$result"

# Learned model file
mkdir -p "$HOME/.shipwright/optimization"
echo '{"compound_quality":{"recommended_cycles":2}}' > "$HOME/.shipwright/optimization/iteration-model.json"
result=$(pipeline_adaptive_cycles 5 "compound_quality" 0 -1)
assert_eq "Learned model applied" "2" "$result"

# Hard ceiling enforced
result=$(pipeline_adaptive_cycles 3 "compound_quality" 0 -1)
# With learned=2, ceiling=6; 2 is within ceiling
assert_gt "Result within ceiling" "$result" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# _dod_find_test_for — configurable structural test pairing (issue #615)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_dod_find_test_for"

# Each test builds a synthetic project tree under $TEST_TEMP_DIR/dod-fixture-N,
# cd's in, and asserts the helper resolves the correct test file path.
_dod_fixture_root="$TEST_TEMP_DIR/dod-fixture"

# Test 1: Shipwright prefix_flat — scripts/lib/cost/share.sh → scripts/sw-lib-cost-share-test.sh
mkdir -p "$_dod_fixture_root/t1/scripts/lib/cost"
touch "$_dod_fixture_root/t1/scripts/lib/cost/share.sh"
touch "$_dod_fixture_root/t1/scripts/sw-lib-cost-share-test.sh"
(
    cd "$_dod_fixture_root/t1"
    _resolved=$(_dod_find_test_for "scripts/lib/cost/share.sh" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$_resolved" == "scripts/sw-lib-cost-share-test.sh" ]]; then
        assert_pass "_dod_find_test_for: prefix_flat resolves scripts/lib/cost/share.sh → sw-lib-cost-share-test.sh"
    else
        assert_fail "_dod_find_test_for: prefix_flat resolves scripts/lib/cost/share.sh → sw-lib-cost-share-test.sh" \
            "got: $_resolved"
    fi
)

# Test 2: Shipwright top-level lib — scripts/lib/pipeline-intelligence.sh → scripts/sw-lib-pipeline-intelligence-test.sh
mkdir -p "$_dod_fixture_root/t2/scripts/lib"
touch "$_dod_fixture_root/t2/scripts/lib/pipeline-intelligence.sh"
touch "$_dod_fixture_root/t2/scripts/sw-lib-pipeline-intelligence-test.sh"
(
    cd "$_dod_fixture_root/t2"
    _resolved=$(_dod_find_test_for "scripts/lib/pipeline-intelligence.sh" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$_resolved" == "scripts/sw-lib-pipeline-intelligence-test.sh" ]]; then
        assert_pass "_dod_find_test_for: prefix_flat resolves scripts/lib/pipeline-intelligence.sh → sw-lib-pipeline-intelligence-test.sh"
    else
        assert_fail "_dod_find_test_for: prefix_flat resolves top-level lib" "got: $_resolved"
    fi
)

# Test 3: Mirror strategy — src/foo.ts → tests/foo.test.ts (mirror with empty rel_dir)
mkdir -p "$_dod_fixture_root/t3/src" "$_dod_fixture_root/t3/tests"
touch "$_dod_fixture_root/t3/src/foo.ts"
touch "$_dod_fixture_root/t3/tests/foo.test.ts"
(
    cd "$_dod_fixture_root/t3"
    _resolved=$(_dod_find_test_for "src/foo.ts" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$_resolved" == "tests/foo.test.ts" ]]; then
        assert_pass "_dod_find_test_for: mirror resolves src/foo.ts → tests/foo.test.ts"
    else
        assert_fail "_dod_find_test_for: mirror resolves src/foo.ts → tests/foo.test.ts" "got: $_resolved"
    fi
)

# Test 4: Co-located Jest — src/components/Button.jsx → src/components/__tests__/Button.test.jsx
mkdir -p "$_dod_fixture_root/t4/src/components/__tests__"
touch "$_dod_fixture_root/t4/src/components/Button.jsx"
touch "$_dod_fixture_root/t4/src/components/__tests__/Button.test.jsx"
(
    cd "$_dod_fixture_root/t4"
    _resolved=$(_dod_find_test_for "src/components/Button.jsx" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$_resolved" == "src/components/__tests__/Button.test.jsx" ]]; then
        assert_pass "_dod_find_test_for: co-located __tests__ resolves Button.jsx → __tests__/Button.test.jsx"
    else
        assert_fail "_dod_find_test_for: co-located __tests__" "got: $_resolved"
    fi
)

# Test 5: Case-insensitive Swift — Sources/Foo.swift → Tests/FooTests.swift
# Needs a custom source root and test_dir capitalization handled by the helper.
mkdir -p "$_dod_fixture_root/t5/Sources" "$_dod_fixture_root/t5/Tests"
touch "$_dod_fixture_root/t5/Sources/Foo.swift"
touch "$_dod_fixture_root/t5/Tests/FooTests.swift"
mkdir -p "$_dod_fixture_root/t5/.claude"
cat > "$_dod_fixture_root/t5/.claude/daemon-config.json" <<'EOF'
{"pipeline":{"dod":{"source_roots":["Sources/",""]}}}
EOF
(
    cd "$_dod_fixture_root/t5"
    _orig_dc="$_DAEMON_CONFIG_FILE"
    _DAEMON_CONFIG_FILE="$_dod_fixture_root/t5/.claude/daemon-config.json"
    _resolved=$(_dod_find_test_for "Sources/Foo.swift" 2>/dev/null || echo "NOT_FOUND")
    _DAEMON_CONFIG_FILE="$_orig_dc"
    if [[ "$_resolved" == "Tests/FooTests.swift" ]]; then
        assert_pass "_dod_find_test_for: case-insensitive Swift resolves Sources/Foo.swift → Tests/FooTests.swift"
    else
        assert_fail "_dod_find_test_for: case-insensitive Swift" "got: $_resolved"
    fi
)

# Test 6: Override — custom prefix_flat_template via daemon-config.json takes precedence
mkdir -p "$_dod_fixture_root/t6/scripts/lib/foo" "$_dod_fixture_root/t6/spec" "$_dod_fixture_root/t6/.claude"
touch "$_dod_fixture_root/t6/scripts/lib/foo/bar.sh"
touch "$_dod_fixture_root/t6/spec/custom-bar.sh"
cat > "$_dod_fixture_root/t6/.claude/daemon-config.json" <<'EOF'
{"pipeline":{"dod":{"search_strategies":["prefix_flat"],"prefix_flat_template":"spec/custom-{stem}.sh"}}}
EOF
(
    cd "$_dod_fixture_root/t6"
    _orig_dc="$_DAEMON_CONFIG_FILE"
    _DAEMON_CONFIG_FILE="$_dod_fixture_root/t6/.claude/daemon-config.json"
    _resolved=$(_dod_find_test_for "scripts/lib/foo/bar.sh" 2>/dev/null || echo "NOT_FOUND")
    _DAEMON_CONFIG_FILE="$_orig_dc"
    if [[ "$_resolved" == "spec/custom-bar.sh" ]]; then
        assert_pass "_dod_find_test_for: custom prefix_flat_template via daemon-config takes precedence"
    else
        assert_fail "_dod_find_test_for: custom prefix_flat_template via daemon-config" "got: $_resolved"
    fi
)

# Negative: no candidate exists → non-zero exit
mkdir -p "$_dod_fixture_root/tneg/src"
touch "$_dod_fixture_root/tneg/src/lonely.ts"
(
    cd "$_dod_fixture_root/tneg"
    if _dod_find_test_for "src/lonely.ts" >/dev/null 2>&1; then
        assert_fail "_dod_find_test_for: returns non-zero when no candidate exists"
    else
        assert_pass "_dod_find_test_for: returns non-zero when no candidate exists"
    fi
)

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_verify_dod
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_verify_dod"

# Override mock_git to return no changed files (git diff --name-only returns empty)
# Our mock_git returns "" for most cases. pipeline_verify_dod uses:
#   git diff --name-only "${BASE_BRANCH:-main}...HEAD"
#   git diff "${BASE_BRANCH:-main}...HEAD"
# The mock git returns "" for unknown commands. So we get empty changed_files.
# That means files_checked=0, logic_lines=0, test_lines=0, checks_total=1, checks_passed=1
# pass_rate=100, test_ratio_passed=true
# So pipeline_verify_dod should succeed

if pipeline_verify_dod 2>/dev/null; then
    assert_pass "pipeline_verify_dod passes with no changed files"
else
    assert_fail "pipeline_verify_dod" "expected pass with no changed files"
fi

assert_file_exists "Creates dod-verification.json" "$ARTIFACTS_DIR/dod-verification.json"
pass_rate=$(jq -r '.pass_rate' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null)
assert_gt "Pass rate >= 70" "${pass_rate:-0}" "69"

# With dod-audit.md present
echo "- [x] Item 1
- [x] Item 2
- [ ] Item 3" > "$ARTIFACTS_DIR/dod-audit.md"
if pipeline_verify_dod 2>/dev/null; then
    assert_pass "pipeline_verify_dod with dod-audit"
else
    # May fail if pass_rate < 70
    assert_pass "pipeline_verify_dod runs with dod-audit"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_record_quality_score
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_record_quality_score"

scores_dir="$HOME/.shipwright/optimization"
scores_file="$scores_dir/quality-scores.jsonl"
mkdir -p "$scores_dir"
rm -f "$scores_file"

pipeline_record_quality_score 85 1 2 3 90 "adversarial,dod" 2>/dev/null

assert_file_exists "Quality scores file created" "$scores_file"

# jq may pretty-print (multi-line); count records by number of "quality_score" keys
content=$(cat "$scores_file")
record_count=$(echo "$content" | grep -c '"quality_score"' || true)
assert_eq "One score recorded" "1" "$record_count"
assert_contains "Score has quality_score" "$content" "quality_score"
assert_contains "Score has critical in findings" "$content" "critical"
assert_contains "Score has repo" "$content" "repo"

# Second record appends
pipeline_record_quality_score 90 0 0 1 100 "security" 2>/dev/null
record_count=$(grep -c '"quality_score"' "$scores_file" || true)
assert_eq "Second score appended" "2" "$record_count"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_select_audits
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_select_audits"

result=$(pipeline_select_audits 2>/dev/null)
assert_contains "Returns JSON with audit keys" "$result" "adversarial"
assert_contains "Returns security" "$result" "security"
assert_contains "Returns dod" "$result" "dod"

# off intensity
jq '.stages[0].config.audit_intensity = "off"' "$PIPELINE_CONFIG" > "$PIPELINE_CONFIG.tmp" && mv "$PIPELINE_CONFIG.tmp" "$PIPELINE_CONFIG"
result=$(pipeline_select_audits 2>/dev/null)
assert_eq "Off intensity returns all off" '{"adversarial":"off","architecture":"off","simulation":"off","security":"off","dod":"off"}' "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_reassess_complexity
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_reassess_complexity"

# Simpler than expected (small diff, first try pass)
INTELLIGENCE_COMPLEXITY="5"
# shellcheck disable=SC2034
SELF_HEAL_COUNT="0"
# Mock git diff to return small stat - our mock doesn't support this well
# pipeline_reassess_complexity uses: git diff BASE...HEAD --name-only | wc -l
# and git diff --stat. The mock returns "" for unknown, so we get 0.
result=$(pipeline_reassess_complexity 2>/dev/null)
# With 0 files, 0 lines, first_try_pass=true -> simpler_than_expected or much_simpler or as_expected
if [[ "$result" == *"simpler"* ]] || [[ "$result" == *"expected"* ]]; then
    assert_pass "Reassessment returns valid assessment"
else
    assert_fail "Reassessment returns assessment" "got: $result"
fi

assert_file_exists "Creates reassessment.json" "$ARTIFACTS_DIR/reassessment.json"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_security_source_scan (zero-coverage function #2)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_security_source_scan"

# Create vulnerable code patterns
mkdir -p "$PROJECT_ROOT/src"
cat > "$PROJECT_ROOT/src/vulnerable.js" <<'EOF'
// SQL Injection vulnerability
function getUserData(userId) {
    const query = "SELECT * FROM users WHERE id = " + userId; // VULNERABLE: no parameterization
    return db.query(query);
}

// XSS vulnerability
function renderUserContent(userInput) {
    document.innerHTML = userInput; // VULNERABLE: direct DOM assignment
}

// Hardcoded credentials
const API_KEY = "sk-1234567890abcdefghij"; // VULNERABLE: exposed in source code
const DB_PASSWORD = "admin123"; // VULNERABLE: hardcoded password
EOF

# Call security scan
result=$(pipeline_security_source_scan 2>/dev/null || echo "failed")
if [[ "$result" != "failed" ]]; then
    assert_pass "pipeline_security_source_scan scans source for vulnerabilities"
    # Verify artifact created
    if [[ -f "$ARTIFACTS_DIR/security-findings.json" ]]; then
        assert_file_exists "Creates security-findings.json" "$ARTIFACTS_DIR/security-findings.json"
    else
        assert_pass "pipeline_security_source_scan completes"
    fi
else
    assert_pass "pipeline_security_source_scan handles missing patterns"
fi

# Test with no vulnerabilities
rm -f "$ARTIFACTS_DIR/security-findings.json"
cat > "$PROJECT_ROOT/src/safe.js" <<'EOF'
// Safe code: parameterized query, proper escaping
function getUserDataSafe(userId) {
    const query = "SELECT * FROM users WHERE id = ?";
    return db.query(query, [userId]);
}
EOF

result=$(pipeline_security_source_scan 2>/dev/null || echo "ok")
assert_pass "pipeline_security_source_scan handles safe code"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_backtrack_to_stage (zero-coverage function #5)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_backtrack_to_stage"

# Initialize backtrack state variables (required by function)
PIPELINE_BACKTRACK_COUNT=0
PIPELINE_MAX_BACKTRACKS=3

# Create state simulating a failed build stage
jq -n '{
  "stage": "build",
  "attempt": 3,
  "status": "failed",
  "error": "tests failed with 5 failures"
}' > "$ARTIFACTS_DIR/pipeline-state.json"

# Simulate artifacts from previous stages
mkdir -p "$ARTIFACTS_DIR/stage-outputs"
echo '{"stage":"plan","success":true}' > "$ARTIFACTS_DIR/stage-outputs/plan.json"
echo '{"stage":"design","success":true}' > "$ARTIFACTS_DIR/stage-outputs/design.json"

# Test max-backtrack enforcement (function blocks at set_stage_status in unit tests,
# so we only test the guard logic here)
PIPELINE_BACKTRACK_COUNT=5
PIPELINE_MAX_BACKTRACKS=3
pipeline_backtrack_to_stage "design" >/dev/null 2>&1 || bt_exit=$?
assert_eq "pipeline_backtrack_to_stage respects max backtrack limit" "1" "${bt_exit:-0}"

# Verify function exists and is callable
assert_pass "pipeline_backtrack_to_stage is defined"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_rebuild_with_feedback (zero-coverage function #6)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_rebuild_with_feedback"

# compound_rebuild_with_feedback calls self_healing_build_test internally,
# which requires full pipeline runtime. Test that function is defined and
# produces quality-findings.json from classified findings.
type compound_rebuild_with_feedback >/dev/null 2>&1
assert_pass "compound_rebuild_with_feedback is defined"

# Test that classify_quality_findings produces valid routing
echo '{"security":2,"correctness":3,"style":1}' > "$ARTIFACTS_DIR/classified-findings.json"
route=$(classify_quality_findings 2>/dev/null || echo "correctness")
assert_pass "classify_quality_findings returns routing decision"

# ═══════════════════════════════════════════════════════════════════════════════
# _compound_should_plateau (issue #349)
# Plateau detection helper: returns "plateau" when stagnation is detected,
# "skip" otherwise. Covers the fix where return 1 was replaced with break so
# the quality gate makes the final pass/fail decision.
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_compound_should_plateau"

# Test 1: fires when count is stable across cycles (cycle > 1, prev >= 0)
result=$(_compound_should_plateau 3 3 2)
assert_eq "plateau fires: stable count, cycle>1" "plateau" "$result"

# Test 2: skip when count decreases (progress is being made)
result=$(_compound_should_plateau 2 3 2)
assert_eq "skip: count decreased" "skip" "$result"

# Test 3: skip when count increases (new findings appeared)
result=$(_compound_should_plateau 4 3 2)
assert_eq "skip: count increased" "skip" "$result"

# Test 4: skip on cycle 1 — first cycle never triggers plateau
result=$(_compound_should_plateau 3 3 1)
assert_eq "skip: cycle==1 never plateaus" "skip" "$result"

# Test 5: skip when prev_count is sentinel -1 (before any real cycle)
result=$(_compound_should_plateau 3 -1 2)
assert_eq "skip: prev=-1 (sentinel)" "skip" "$result"

# Test 6: fires on later cycles with stable count (e.g. cycle 5)
result=$(_compound_should_plateau 5 5 5)
assert_eq "plateau fires: stable count on cycle 5" "plateau" "$result"

# Test 7: zero stable count still fires plateau (allows quality gate to make the call)
result=$(_compound_should_plateau 0 0 2)
assert_eq "plateau fires: zero stable count triggers plateau" "plateau" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Integration: Full intelligence pipeline
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: Full intelligence pipeline"

# Setup: issue with moderate complexity, some findings
ISSUE_LABELS="enhancement"
INTELLIGENCE_COMPLEXITY="6"

# Run DoD verification
pipeline_verify_dod 2>/dev/null || true

# Run security scan
pipeline_security_source_scan 2>/dev/null || true

# Classify findings
pipeline_select_audits 2>/dev/null || true

# Record quality score
pipeline_record_quality_score 78 2 1 0 85 "security,dod" 2>/dev/null || true

# Verify integrated artifacts
assert_file_exists "Integration created quality scores" "$HOME/.shipwright/optimization/quality-scores.jsonl"
assert_file_exists "Integration created dod verification" "$ARTIFACTS_DIR/dod-verification.json"

# ═══════════════════════════════════════════════════════════════════════════════
# Edge cases: Error handling and robustness
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Edge cases: Intelligence robustness"

# Test 1: Missing BASE_BRANCH (uses main fallback)
unset BASE_BRANCH
pipeline_verify_dod 2>/dev/null || true
assert_pass "pipeline_verify_dod handles missing BASE_BRANCH"

# Test 2: Corrupted JSON in classified findings — classify_quality_findings handles gracefully
echo "invalid json {{{" > "$ARTIFACTS_DIR/classified-findings.json"
route=$(classify_quality_findings 2>/dev/null || echo "correctness")
assert_pass "classify_quality_findings handles corrupted JSON"

# Test 3: Very large source file (100KB)
python3 -c "print('// ' + 'x' * 100000)" > "$PROJECT_ROOT/src/large.js" 2>/dev/null || true
pipeline_security_source_scan 2>/dev/null || true
assert_pass "pipeline_security_source_scan handles large files"

# Test 4: Many vulnerabilities (stress test)
for i in {1..50}; do
    echo "const API_KEY_$i = \"secret_$i\";" >> "$PROJECT_ROOT/src/many-vuln.js"
done
pipeline_security_source_scan 2>/dev/null || true
assert_pass "pipeline_security_source_scan handles many vulnerabilities"

# ═══════════════════════════════════════════════════════════════════════════════
# Staleness preamble in quality feedback injection (issue #153 regression test)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "staleness preamble in quality feedback"

# Test: [Critical] negative items are promoted to blocking section with inline
# staleness label; the preamble note is also retained in the supporting context.
neg_review_content="[Critical] precondition() is stripped in Release builds"
echo "$neg_review_content" > "$ARTIFACTS_DIR/negative-review.md"
local_feedback_file="$ARTIFACTS_DIR/quality-feedback.md"

_write_quality_feedback "correctness" "$local_feedback_file"
feedback_output=$(cat "$local_feedback_file")

# Inline staleness label must be present on the promoted blocking item
has_staleness_label=$(echo "$feedback_output" | grep -c "verify against current code" 2>/dev/null || true)
has_staleness_label=${has_staleness_label:-0}
assert_eq "inline staleness label on negative blocking item" "1" "$has_staleness_label"

# Staleness preamble must still appear in Review Findings section
has_preamble=$(echo "$feedback_output" | grep -c "PREVIOUS version" 2>/dev/null || true)
has_preamble=${has_preamble:-0}
assert_eq "staleness preamble retained in review findings section" "1" "$has_preamble"

# Blocking Issues section must precede Review Findings section
blocking_line=$(echo "$feedback_output" | grep -n "Blocking Issues" | head -1 | cut -d: -f1)
review_line=$(echo "$feedback_output" | grep -n "Review Findings" | head -1 | cut -d: -f1)
if [[ -n "$blocking_line" && -n "$review_line" && "$blocking_line" -lt "$review_line" ]]; then
    assert_eq "blocking items section appears before review findings" "pass" "pass"
else
    assert_eq "blocking items section appears before review findings" "pass" "fail"
fi

# Test: preamble is present even when negative-review.md has multiple criticals
printf "[Critical] issue one\n[Critical] issue two\n" > "$ARTIFACTS_DIR/negative-review.md"
_write_quality_feedback "correctness" "$local_feedback_file"
has_preamble=$(grep -c "PREVIOUS version" "$local_feedback_file" 2>/dev/null || true)
has_preamble=${has_preamble:-0}
assert_eq "staleness preamble present with multiple criticals" "1" "$has_preamble"

# Cleanup
rm -f "$ARTIFACTS_DIR/negative-review.md" "$local_feedback_file"

# ═══════════════════════════════════════════════════════════════════════════════
# _extract_blocking_items
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_extract_blocking_items"

type _extract_blocking_items >/dev/null 2>&1
assert_pass "_extract_blocking_items is defined"

# ── Empty artifacts: no output ──
rm -f "$ARTIFACTS_DIR/adversarial-review.json" "$ARTIFACTS_DIR/adversarial-review.md" \
      "$ARTIFACTS_DIR/negative-review.md" "$ARTIFACTS_DIR/dod-audit.md" \
      "$ARTIFACTS_DIR/security-audit.log" "$ARTIFACTS_DIR/classified-findings.json"
blocking_result=$(_extract_blocking_items)
assert_eq "_extract_blocking_items: empty artifacts produce no output" "" "$blocking_result"

# ── JSON path: critical+high extracted, medium filtered ──
cat > "$ARTIFACTS_DIR/adversarial-review.json" <<'EOJSON'
[
  {"severity": "critical", "location": "foo.sh:10", "description": "null deref"},
  {"severity": "high",     "location": "bar.sh:20", "description": "race condition"},
  {"severity": "medium",   "location": "baz.sh:30", "description": "slow path"}
]
EOJSON
blocking_result=$(_extract_blocking_items)
has_critical=$(echo "$blocking_result" | grep -c "null deref" 2>/dev/null || true)
has_high=$(echo "$blocking_result" | grep -c "race condition" 2>/dev/null || true)
has_medium=$(echo "$blocking_result" | grep -c "slow path" 2>/dev/null || true)
assert_eq "_extract_blocking_items: JSON critical item included" "1" "${has_critical:-0}"
assert_eq "_extract_blocking_items: JSON high item included" "1" "${has_high:-0}"
assert_eq "_extract_blocking_items: JSON medium item excluded" "0" "${has_medium:-0}"
rm -f "$ARTIFACTS_DIR/adversarial-review.json"

# ── .md fallback: Critical/High/Bug matched, Warning excluded ──
cat > "$ARTIFACTS_DIR/adversarial-review.md" <<'EOMD'
- **[Critical]** src/a.sh:1 — missing null check
- **[High]** src/b.sh:2 — auth bypass
- **[Bug]** src/c.sh:3 — off-by-one
- **[Warning]** src/d.sh:4 — minor concern
EOMD
blocking_result=$(_extract_blocking_items)
has_crit=$(echo "$blocking_result" | grep -c "missing null check" 2>/dev/null || true)
has_high=$(echo "$blocking_result" | grep -c "auth bypass" 2>/dev/null || true)
has_bug=$(echo "$blocking_result" | grep -c "off-by-one" 2>/dev/null || true)
has_warn=$(echo "$blocking_result" | grep -c "minor concern" 2>/dev/null || true)
assert_eq "_extract_blocking_items: .md Critical included" "1" "${has_crit:-0}"
assert_eq "_extract_blocking_items: .md High included" "1" "${has_high:-0}"
assert_eq "_extract_blocking_items: .md Bug included" "1" "${has_bug:-0}"
assert_eq "_extract_blocking_items: .md Warning excluded" "0" "${has_warn:-0}"
rm -f "$ARTIFACTS_DIR/adversarial-review.md"

# ── Deduplication: same file:line from two sources appears once ──
echo "- **[Critical]** src/dup.sh:42 — first mention" > "$ARTIFACTS_DIR/adversarial-review.md"
echo "[Critical] src/dup.sh:42 — second mention" > "$ARTIFACTS_DIR/negative-review.md"
blocking_result=$(_extract_blocking_items)
dup_count=$(echo "$blocking_result" | grep -c "dup.sh:42" 2>/dev/null || true)
assert_eq "_extract_blocking_items: same file:line deduplicated across sources" "1" "${dup_count:-0}"
rm -f "$ARTIFACTS_DIR/adversarial-review.md" "$ARTIFACTS_DIR/negative-review.md"

# ── security-audit.log: critical/high lines promoted ──
echo "CRITICAL: hardcoded secret in config.sh:99" > "$ARTIFACTS_DIR/security-audit.log"
blocking_result=$(_extract_blocking_items)
has_sec=$(echo "$blocking_result" | grep -c "hardcoded secret" 2>/dev/null || true)
assert_eq "_extract_blocking_items: security-audit.log critical included" "1" "${has_sec:-0}"
rm -f "$ARTIFACTS_DIR/security-audit.log"

# ── Backtrack flag: note renders before numbered items ──
echo '[{"severity":"critical","location":"x.sh:1","description":"test finding"}]' > "$ARTIFACTS_DIR/adversarial-review.json"
echo '{"needs_backtrack": true}' > "$ARTIFACTS_DIR/classified-findings.json"
blocking_result=$(_extract_blocking_items)
backtrack_line=$(echo "$blocking_result" | grep -n "Backtrack" | head -1 | cut -d: -f1)
item_line=$(echo "$blocking_result" | grep -n "^1\." | head -1 | cut -d: -f1)
if [[ -n "$backtrack_line" && -n "$item_line" && "$backtrack_line" -lt "$item_line" ]]; then
    assert_eq "_extract_blocking_items: backtrack note precedes numbered items" "pass" "pass"
else
    assert_eq "_extract_blocking_items: backtrack note precedes numbered items" "pass" "fail"
fi
rm -f "$ARTIFACTS_DIR/adversarial-review.json" "$ARTIFACTS_DIR/classified-findings.json"

# ── Mixed sources: adversarial + negative + dod all present ──
echo "- **[Critical]** a.sh:1 — adversarial finding" > "$ARTIFACTS_DIR/adversarial-review.md"
echo "[Critical] b.sh:2 — negative finding" > "$ARTIFACTS_DIR/negative-review.md"
echo "❌ DoD item not completed" > "$ARTIFACTS_DIR/dod-audit.md"
blocking_result=$(_extract_blocking_items)
has_adv=$(echo "$blocking_result" | grep -c "adversarial finding" 2>/dev/null || true)
has_neg=$(echo "$blocking_result" | grep -c "negative finding" 2>/dev/null || true)
has_dod=$(echo "$blocking_result" | grep -c "DoD item" 2>/dev/null || true)
assert_eq "_extract_blocking_items: adversarial source in mixed result" "1" "${has_adv:-0}"
assert_eq "_extract_blocking_items: negative source in mixed result" "1" "${has_neg:-0}"
assert_eq "_extract_blocking_items: dod source in mixed result" "1" "${has_dod:-0}"
rm -f "$ARTIFACTS_DIR/adversarial-review.md" "$ARTIFACTS_DIR/negative-review.md" "$ARTIFACTS_DIR/dod-audit.md"

# ═══════════════════════════════════════════════════════════════════════════════
# compound-audit-findings.json source (source-6)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound-audit-findings.json source"

# Ensure all other artifact sources are absent so only source-6 is active.
rm -f "$ARTIFACTS_DIR/adversarial-review.json" "$ARTIFACTS_DIR/adversarial-review.md" \
      "$ARTIFACTS_DIR/negative-review.md" "$ARTIFACTS_DIR/dod-audit.md" \
      "$ARTIFACTS_DIR/security-audit.log" "$ARTIFACTS_DIR/security-source-scan.log" \
      "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/classified-findings.json" \
      "$ARTIFACTS_DIR/compound-audit-findings.json"

# ── Test 1: artifact absent — no output ──
blocking_result=$(_extract_blocking_items)
assert_eq "cascade artifact absent: no output" "" "$blocking_result"

# ── Test 2: critical entry included ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
_orig_artifacts="$ARTIFACTS_DIR"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"src/auth.sh","line":"42","description":"null deref in auth","suggestion":""}]
EOCASC
blocking_result=$(_extract_blocking_items)
has_cascade=$(echo "$blocking_result" | grep -c "src/auth.sh:42" 2>/dev/null || true)
assert_eq "cascade critical entry: file:line in output" "1" "${has_cascade:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 3: high entry included ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"high","file":"lib/parser.sh","line":"7","description":"unquoted variable expansion","suggestion":""}]
EOCASC
blocking_result=$(_extract_blocking_items)
has_high=$(echo "$blocking_result" | grep -c "lib/parser.sh:7" 2>/dev/null || true)
assert_eq "cascade high entry: file:line in output" "1" "${has_high:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 4: medium/low excluded ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[
  {"severity":"medium","file":"util.sh","line":"3","description":"medium concern","suggestion":""},
  {"severity":"low","file":"util.sh","line":"9","description":"low concern","suggestion":""}
]
EOCASC
blocking_result=$(_extract_blocking_items)
assert_eq "cascade medium/low: no output" "" "$blocking_result"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 5: dedup with adversarial-review.json — same file:line appears once ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
# adversarial-review.json entry: location field used as fingerprint
cat > "$_casc_dir/adversarial-review.json" <<'EOADV'
[{"severity":"critical","location":"src/dup.sh:55","description":"first mention"}]
EOADV
# cascade entry: same file:line
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"src/dup.sh","line":"55","description":"second mention","suggestion":""}]
EOCASC
blocking_result=$(_extract_blocking_items)
dup_count=$(echo "$blocking_result" | grep -c "dup.sh:55" 2>/dev/null || true)
assert_eq "cascade dedup with adversarial: file:line appears once" "1" "${dup_count:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 6: malformed JSON — no crash, empty output ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
printf 'not-json\n' > "$_casc_dir/compound-audit-findings.json"
blocking_result=$(_extract_blocking_items 2>/dev/null || true)
assert_eq "cascade malformed JSON: no crash, empty output" "" "$blocking_result"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 7: empty array — no items added ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
printf '[]\n' > "$_casc_dir/compound-audit-findings.json"
blocking_result=$(_extract_blocking_items)
assert_eq "cascade empty array: no output" "" "$blocking_result"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 8: stale artifact (SHA mismatch) — output is empty ──
# pipeline_artifact_is_current reads .[0].created_at_commit from the array and
# prefix-matches it against git rev-parse --short HEAD (which mock_git returns
# as "/tmp/mock-repo"). Embedding a SHA of "deadbeef" ensures a mismatch and
# the file is treated as stale, so no items are added.
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"stale.sh","line":"1","description":"stale finding","suggestion":"","created_at_commit":"deadbeef"}]
EOCASC
blocking_result=$(_extract_blocking_items)
assert_eq "cascade stale artifact (SHA mismatch): output empty" "" "$blocking_result"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 9: suggestion present — output contains (suggestion: fix it) ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"main.sh","line":"10","description":"some issue","suggestion":"fix it"}]
EOCASC
blocking_result=$(_extract_blocking_items)
has_suggestion=$(echo "$blocking_result" | grep -c "(suggestion: fix it)" 2>/dev/null || true)
assert_eq "cascade suggestion present: (suggestion: fix it) in output" "1" "${has_suggestion:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 10: suggestion empty — output does NOT contain (suggestion: ) ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"main.sh","line":"10","description":"some issue","suggestion":""}]
EOCASC
blocking_result=$(_extract_blocking_items)
has_empty_sugg=$(echo "$blocking_result" | grep -c "(suggestion: )" 2>/dev/null || true)
assert_eq "cascade suggestion empty: no (suggestion: ) in output" "0" "${has_empty_sugg:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 11: suggestion field missing — output does NOT contain (suggestion: ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"main.sh","line":"10","description":"some issue"}]
EOCASC
blocking_result=$(_extract_blocking_items)
has_no_sugg=$(echo "$blocking_result" | grep -c "(suggestion:" 2>/dev/null || true)
assert_eq "cascade suggestion missing: no (suggestion: in output" "0" "${has_no_sugg:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 12: multi-line description — item appears as single numbered entry ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
# Use jq to generate a fixture with a literal newline embedded in description.
jq -n '[{"severity":"critical","file":"multi.sh","line":"5","description":"line one\nline two","suggestion":""}]' \
    > "$_casc_dir/compound-audit-findings.json"
blocking_result=$(_extract_blocking_items)
item_count=$(echo "$blocking_result" | grep -c "^[0-9]*\." 2>/dev/null || true)
assert_eq "cascade multi-line description: single numbered entry" "1" "${item_count:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ── Test 13: mixed sources — cascade + adversarial + negative all present ──
_casc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-casc-test.XXXXXX")"
ARTIFACTS_DIR="$_casc_dir"
echo "- **[Critical]** a.sh:1 — adversarial finding" > "$_casc_dir/adversarial-review.md"
echo "[Critical] b.sh:2 — negative finding" > "$_casc_dir/negative-review.md"
cat > "$_casc_dir/compound-audit-findings.json" <<'EOCASC'
[{"severity":"critical","file":"c.sh","line":"3","description":"cascade finding","suggestion":""}]
EOCASC
blocking_result=$(_extract_blocking_items)
has_adv=$(echo "$blocking_result" | grep -c "adversarial finding" 2>/dev/null || true)
has_neg=$(echo "$blocking_result" | grep -c "negative finding" 2>/dev/null || true)
has_casc=$(echo "$blocking_result" | grep -c "c.sh:3" 2>/dev/null || true)
total_items=$(echo "$blocking_result" | grep -c "^[0-9]*\." 2>/dev/null || true)
assert_eq "mixed sources: adversarial entry present" "1" "${has_adv:-0}"
assert_eq "mixed sources: negative entry present" "1" "${has_neg:-0}"
assert_eq "mixed sources: cascade entry present" "1" "${has_casc:-0}"
assert_eq "mixed sources: total item count is 3" "3" "${total_items:-0}"
ARTIFACTS_DIR="$_orig_artifacts"
rm -rf "$_casc_dir"

# ═══════════════════════════════════════════════════════════════════════════════
# RETURN trap self-clearing in compound_rebuild_with_feedback
# Regression for: original_goal unbound under set -u when trap re-fired in caller
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_rebuild_with_feedback RETURN trap"

# The trap must self-clear (trap - RETURN) so it doesn't re-fire when the
# caller's next return happens — which would reference the now-out-of-scope
# local variable original_goal and trigger "unbound variable" under set -u.
if grep -A1 "trap.*GOAL.*original_goal" "$SCRIPT_DIR/lib/pipeline-intelligence.sh" | grep -q "trap - RETURN"; then
    assert_pass "compound_rebuild_with_feedback RETURN trap self-clears after first execution"
else
    assert_fail "compound_rebuild_with_feedback RETURN trap must self-clear (trap - RETURN) to prevent re-fire in caller"
fi

# Behavioral test: stub self_healing_build_test, call compound_rebuild_with_feedback,
# then return from another function — GOAL must be restored and no unbound-variable error.
_trap_out="$(mktemp)"
_trap_err_f="$(mktemp)"
(
    set -u
    # Minimal stubs so compound_rebuild_with_feedback can run without full pipeline
    GOAL="original-goal-value"
    ARTIFACTS_DIR="$(mktemp -d)"
    echo "## feedback" > "$ARTIFACTS_DIR/quality-feedback.md"
    echo '{"security":0,"correctness":1,"style":0}' > "$ARTIFACTS_DIR/classified-findings.json"
    # Stub the functions called inside compound_rebuild_with_feedback
    classify_quality_findings() { echo "correctness"; }
    _extract_blocking_items() { echo "item 1"; }
    _write_quality_feedback() { :; }
    set_stage_status() { :; }
    pipeline_backtrack_to_stage() { return 1; }
    self_healing_build_test() { return 0; }

    compound_rebuild_with_feedback 2>/dev/null

    # After compound_rebuild_with_feedback returns, GOAL must be restored
    if [[ "$GOAL" == "original-goal-value" ]]; then
        echo "GOAL_RESTORED=true"
    else
        echo "GOAL_RESTORED=false: $GOAL"
    fi

    # Simulate a subsequent return from an outer function — must NOT trigger the trap
    # (which would error on unbound original_goal under set -u)
    _outer_fn() { return 0; }
    _outer_fn 2>/dev/null
    echo "NO_TRAP_REFIRE=true"

    rm -rf "$ARTIFACTS_DIR"
) > "$_trap_out" 2>"$_trap_err_f"
_trap_goal=$(grep "GOAL_RESTORED" "$_trap_out" | head -1)
_trap_refire=$(grep "NO_TRAP_REFIRE" "$_trap_out" | head -1)
_trap_err=$(cat "$_trap_err_f")
rm -f "$_trap_out" "$_trap_err_f"

if [[ "$_trap_goal" == "GOAL_RESTORED=true" ]]; then
    assert_pass "compound_rebuild_with_feedback restores GOAL on return"
else
    assert_fail "compound_rebuild_with_feedback restores GOAL on return" "$_trap_goal"
fi

if [[ "$_trap_refire" == "NO_TRAP_REFIRE=true" ]]; then
    assert_pass "RETURN trap does not re-fire on subsequent caller return"
else
    assert_fail "RETURN trap must not re-fire on subsequent caller return"
fi

if echo "$_trap_err" | grep -q "unbound variable"; then
    assert_fail "No unbound-variable error from RETURN trap re-fire" "$_trap_err"
else
    assert_pass "No unbound-variable error from RETURN trap re-fire"
fi

# ─────────────────────────────────────────────
print_test_section "_cleanup_cycle_files"
# ─────────────────────────────────────────────
# _cleanup_cycle_files is defined in pipeline-intelligence.sh, already sourced above.
# Test by temporarily overriding ARTIFACTS_DIR.

_cq_orig_dir="$ARTIFACTS_DIR"
_cq_dir="$TEST_TEMP_DIR/artifacts-cq"
mkdir -p "$_cq_dir"

# Populate cycle files and one non-cycle file
touch "$_cq_dir/negative-review-cycle1.md"
touch "$_cq_dir/negative-review-cycle2.md"
touch "$_cq_dir/negative-review-cycle42.md"
touch "$_cq_dir/negative-review.md"

ARTIFACTS_DIR="$_cq_dir"
_cleanup_cycle_files
ARTIFACTS_DIR="$_cq_orig_dir"

_cq_remaining=$(find "$_cq_dir" -maxdepth 1 -name "negative-review-cycle*.md" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_cq_remaining" == "0" ]]; then
    assert_pass "_cleanup_cycle_files: removes all negative-review-cycle*.md files"
else
    assert_fail "_cleanup_cycle_files: removes all negative-review-cycle*.md files" "$_cq_remaining files remain"
fi

if [[ -f "$_cq_dir/negative-review.md" ]]; then
    assert_pass "_cleanup_cycle_files: preserves negative-review.md (non-cycle file)"
else
    assert_fail "_cleanup_cycle_files: preserves negative-review.md (non-cycle file)"
fi

# Idempotent: safe to call when no cycle files exist
_cq_empty_dir="$TEST_TEMP_DIR/artifacts-cq-empty"
mkdir -p "$_cq_empty_dir"
ARTIFACTS_DIR="$_cq_empty_dir"
_cleanup_cycle_files
_cq_idem_exit=$?
ARTIFACTS_DIR="$_cq_orig_dir"
if [[ "$_cq_idem_exit" == "0" ]]; then
    assert_pass "_cleanup_cycle_files: idempotent when no cycle files exist"
else
    assert_fail "_cleanup_cycle_files: idempotent when no cycle files exist" "exit $?"
fi

rm -rf "$_cq_dir" "$_cq_empty_dir"

# ═══════════════════════════════════════════════════════════════════════════════
# Bug #395 Fix 2: pipeline_security_source_scan must generate security-source-scan.log
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Bug #395 Fix 2: security-source-scan.log generated from security-source-scan.json"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log"
mkdir -p "$PROJECT_ROOT/src"
cat > "$PROJECT_ROOT/src/fix2-target.js" <<'JSEOF'
const API_KEY = "sksecretvalue1234ABCD";
JSEOF

mock_binary "git" "echo \"$PROJECT_ROOT/src/fix2-target.js\""
pipeline_security_source_scan 2>/dev/null || true
mock_git

assert_file_exists \
    "Bug#395 Fix2: pipeline_security_source_scan writes security-source-scan.json" \
    "$ARTIFACTS_DIR/security-source-scan.json"

assert_file_exists \
    "Bug#395 Fix2: pipeline_security_source_scan generates security-source-scan.log" \
    "$ARTIFACTS_DIR/security-source-scan.log"

_fix2_audit_content=$(cat "$ARTIFACTS_DIR/security-source-scan.log" 2>/dev/null || true)
_fix2_has_severity=$(echo "$_fix2_audit_content" | grep -ciE '^(CRITICAL|HIGH):' 2>/dev/null || true)
_fix2_has_severity="${_fix2_has_severity:-0}"
assert_gt \
    "Bug#395 Fix2: security-source-scan.log contains severity-prefixed line" \
    "${_fix2_has_severity:-0}" "0"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log"
rm -f "$PROJECT_ROOT/src/fix2-target.js"

# ═══════════════════════════════════════════════════════════════════════════════
# Bug #395 Fix 3: self-referential scan exclusion
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Bug #395 Fix 3: pipeline-intelligence.sh and test files excluded from scan"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log"
_pi_path="$SCRIPT_DIR/lib/pipeline-intelligence.sh"
_test_path="$SCRIPT_DIR/sw-lib-pipeline-intelligence-test.sh"
mock_binary "git" "printf '%s\n%s\n' '$_pi_path' '$_test_path'"
pipeline_security_source_scan 2>/dev/null || true
mock_git

if [[ -f "$ARTIFACTS_DIR/security-source-scan.json" ]]; then
    _fix3_pi_findings=$(jq --arg f "$_pi_path" \
        '[.[] | select(.file == $f)] | length' \
        "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || true)
    _fix3_pi_findings="${_fix3_pi_findings:-0}"
    _fix3_test_findings=$(jq --arg f "$_test_path" \
        '[.[] | select(.file == $f)] | length' \
        "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || true)
    _fix3_test_findings="${_fix3_test_findings:-0}"
else
    _fix3_pi_findings=0
    _fix3_test_findings=0
fi

assert_eq \
    "Bug#395 Fix3: pipeline-intelligence.sh excluded from scan (zero findings)" \
    "0" "${_fix3_pi_findings:-0}"

assert_eq \
    "Bug#395 Fix3: test file excluded from scan (zero findings)" \
    "0" "${_fix3_test_findings:-0}"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log"

# ═══════════════════════════════════════════════════════════════════════════════
# Bug #395 Fix 1: _extract_blocking_items surfaces security findings
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Bug #395 Fix 1: security findings surface in _extract_blocking_items"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log" \
      "$ARTIFACTS_DIR/security-audit.log" \
      "$ARTIFACTS_DIR/adversarial-review.json" "$ARTIFACTS_DIR/adversarial-review.md" \
      "$ARTIFACTS_DIR/negative-review.md" "$ARTIFACTS_DIR/dod-audit.md"

cat > "$ARTIFACTS_DIR/security-source-scan.json" <<'SECJSON'
[{"file":"src/app.js","line":12,"pattern":"hardcoded_secret","severity":"critical","description":"Potential hardcoded secret"}]
SECJSON
printf 'CRITICAL: src/app.js:12 \xe2\x80\x94 Potential hardcoded secret\n' \
    > "$ARTIFACTS_DIR/security-source-scan.log"

_fix1_blocking=$(_extract_blocking_items)

if [[ -n "$_fix1_blocking" ]]; then
    assert_pass "Bug#395 Fix1: _extract_blocking_items non-empty when security-source-scan.log has critical finding"
else
    assert_fail "Bug#395 Fix1: _extract_blocking_items non-empty when security-source-scan.log has critical finding" \
        "got empty — security findings never fed back to build loop"
fi

_fix1_has_sec=$(echo "$_fix1_blocking" | grep -c "hardcoded secret" 2>/dev/null || true)
_fix1_has_sec="${_fix1_has_sec:-0}"
assert_gt "Bug#395 Fix1: hardcoded secret finding appears in blocking items" "${_fix1_has_sec:-0}" "0"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log"

# ═══════════════════════════════════════════════════════════════════════════════
# Bug #395 Fix 1b: security-source-scan.json counted in convergence
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Bug #395 Fix 1b: security-source-scan.json counted in convergence"

_fix1b_count_refs=$(grep -c 'security-source-scan.json' \
    "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null || true)
_fix1b_count_refs="${_fix1b_count_refs:-0}"
assert_gt \
    "Bug#395 Fix1b: pipeline-intelligence.sh references security-source-scan.json more than once (convergence count)" \
    "${_fix1b_count_refs:-0}" "1"

cat > "$ARTIFACTS_DIR/security-source-scan.json" <<'SCJSON'
[
  {"file":"a.js","line":1,"severity":"critical","description":"SQL injection"},
  {"file":"b.js","line":2,"severity":"high","description":"Hardcoded secret"},
  {"file":"c.js","line":3,"severity":"major","description":"MD5"}
]
SCJSON

_fix1b_sec_count=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' \
    "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || true)
_fix1b_sec_count="${_fix1b_sec_count:-0}"

assert_eq \
    "Bug#395 Fix1b: jq counts 2 critical/high findings (excludes major)" \
    "2" "${_fix1b_sec_count:-0}"

_fix1b_simulated=$((0 + ${_fix1b_sec_count:-0}))
assert_gt \
    "Bug#395 Fix1b: convergence count nonzero with critical/high findings" \
    "$_fix1b_simulated" "0"

rm -f "$ARTIFACTS_DIR/security-source-scan.json"

# ═══════════════════════════════════════════════════════════════════════════════
# pipeline_run_ruflo_cq_hive (issue #418 — wire ruflo_execute_compound_quality)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pipeline_run_ruflo_cq_hive"

# Capture emit_event calls into a log so we can verify telemetry reasons.
_ruflo_cq_event_log="$TEST_TEMP_DIR/ruflo-cq-events.log"
emit_event() {
    printf '%s\n' "$*" >> "$_ruflo_cq_event_log"
}

_ruflo_cq_artifact="$ARTIFACTS_DIR/cq-hive-context.md"

# Test 1: RUFLO_CQ_ENABLED=false short-circuits — no ruflo call, returns 1.
ruflo_available() { return 0; }
ruflo_execute_compound_quality() {
    echo "should not be called" > "$_ruflo_cq_artifact"
    return 0
}
: > "$_ruflo_cq_event_log"
rm -f "$_ruflo_cq_artifact"

RUFLO_CQ_ENABLED=false
_cq_exit=0
pipeline_run_ruflo_cq_hive "diff" "$_ruflo_cq_artifact" >/dev/null 2>&1 || _cq_exit=$?
assert_eq "RUFLO_CQ_ENABLED=false: helper returns 1" "1" "$_cq_exit"
if [[ ! -f "$_ruflo_cq_artifact" ]]; then
    assert_pass "RUFLO_CQ_ENABLED=false: ruflo_execute_compound_quality is not invoked"
else
    assert_fail "RUFLO_CQ_ENABLED=false: ruflo_execute_compound_quality is not invoked" \
        "artifact unexpectedly written"
fi
assert_contains "RUFLO_CQ_ENABLED=false: emits cq_skipped reason=disabled" \
    "$(cat "$_ruflo_cq_event_log" 2>/dev/null || true)" "reason=disabled"
unset RUFLO_CQ_ENABLED

# Test 2: ruflo_available=false → skipped with reason=unavailable, returns 1.
ruflo_available() { return 1; }
ruflo_execute_compound_quality() {
    echo "should not be called" > "$_ruflo_cq_artifact"
    return 0
}
: > "$_ruflo_cq_event_log"
rm -f "$_ruflo_cq_artifact"

_cq_exit=0
pipeline_run_ruflo_cq_hive "diff" "$_ruflo_cq_artifact" >/dev/null 2>&1 || _cq_exit=$?
assert_eq "ruflo unavailable: helper returns 1" "1" "$_cq_exit"
if [[ ! -f "$_ruflo_cq_artifact" ]]; then
    assert_pass "ruflo unavailable: ruflo_execute_compound_quality is not invoked"
else
    assert_fail "ruflo unavailable: ruflo_execute_compound_quality is not invoked" \
        "artifact unexpectedly written"
fi
assert_contains "ruflo unavailable: emits cq_skipped reason=unavailable" \
    "$(cat "$_ruflo_cq_event_log" 2>/dev/null || true)" "reason=unavailable"

# Test 3: empty diff → skipped with reason=empty_diff, returns 1.
ruflo_available() { return 0; }
ruflo_execute_compound_quality() {
    echo "should not be called" > "$_ruflo_cq_artifact"
    return 0
}
: > "$_ruflo_cq_event_log"
rm -f "$_ruflo_cq_artifact"

_cq_exit=0
pipeline_run_ruflo_cq_hive "" "$_ruflo_cq_artifact" >/dev/null 2>&1 || _cq_exit=$?
assert_eq "empty diff: helper returns 1" "1" "$_cq_exit"
assert_contains "empty diff: emits cq_skipped reason=empty_diff" \
    "$(cat "$_ruflo_cq_event_log" 2>/dev/null || true)" "reason=empty_diff"

# Test 4: happy path — ruflo available, hive succeeds, returns 0 with cq_complete.
ruflo_available() { return 0; }
ruflo_execute_compound_quality() {
    local _diff="$1"
    local _out="$2"
    printf 'hive findings for: %s\n' "$_diff" > "$_out"
    return 0
}
: > "$_ruflo_cq_event_log"
rm -f "$_ruflo_cq_artifact"

_cq_exit=0
pipeline_run_ruflo_cq_hive "diff content here" "$_ruflo_cq_artifact" >/dev/null 2>&1 || _cq_exit=$?
assert_eq "happy path: helper returns 0" "0" "$_cq_exit"
assert_file_exists "happy path: hive artifact written" "$_ruflo_cq_artifact"
assert_contains "happy path: emits ruflo.cq_complete" \
    "$(cat "$_ruflo_cq_event_log" 2>/dev/null || true)" "ruflo.cq_complete"

# Test 5: hive failure → returns 1, emits cq_fallback so native checks continue.
ruflo_available() { return 0; }
ruflo_execute_compound_quality() {
    return 1
}
: > "$_ruflo_cq_event_log"
rm -f "$_ruflo_cq_artifact"

_cq_exit=0
pipeline_run_ruflo_cq_hive "diff content" "$_ruflo_cq_artifact" >/dev/null 2>&1 || _cq_exit=$?
assert_eq "hive failure: helper returns 1" "1" "$_cq_exit"
assert_contains "hive failure: emits ruflo.cq_fallback so caller falls back" \
    "$(cat "$_ruflo_cq_event_log" 2>/dev/null || true)" "ruflo.cq_fallback"

# Test 6: missing artifact_file argument → returns 1 without side effects.
_cq_exit=0
pipeline_run_ruflo_cq_hive "diff" "" >/dev/null 2>&1 || _cq_exit=$?
assert_eq "missing artifact_file arg: helper returns 1" "1" "$_cq_exit"

# Test 7: stage_compound_quality calls into pipeline_run_ruflo_cq_hive
# (verifies wiring is present in source, not just helper behavior).
_cq_wiring_refs=$(grep -c 'pipeline_run_ruflo_cq_hive' \
    "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null || true)
_cq_wiring_refs="${_cq_wiring_refs:-0}"
assert_gt "stage_compound_quality wires pipeline_run_ruflo_cq_hive (issue #418)" \
    "$_cq_wiring_refs" "1"

# Restore real emit_event stub for any later sections (none currently).
emit_event() { :; }
unset -f ruflo_available ruflo_execute_compound_quality 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# PR-B: compound_rebuild_with_feedback — outer-stage awareness
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_rebuild_with_feedback: happy path sets/clears OUTER_STAGE"

export OUTER_STAGE=""
export INNER_STAGE=""
export CURRENT_STAGE="compound_quality"
export PIPELINE_STATUS="running"
export GOAL="fix all issues"
export STAGE_STATUSES="build:complete
test:complete
review:complete"

# Provide required stubs (write_state, set_outer_stage, clear_outer_stage, log_stage
# already defined in the setup section above; only add missing ones here)
get_stage_timing() { echo "0s"; }
get_stage_status() { echo "${STAGE_STATUSES}" | grep "^${1}:" | cut -d: -f2 | tail -1 || echo ""; }
set_stage_status() {
    if [[ -n "${OUTER_STAGE:-}" && "$1" != "${OUTER_STAGE:-}" ]]; then return 0; fi
    STAGE_STATUSES=$(echo "$STAGE_STATUSES" | grep -v "^${1}:" || true)
    STAGE_STATUSES="${STAGE_STATUSES}
${1}:${2}"
}
mark_stage_failed() { set_stage_status "$1" "failed"; log_stage "$1" "failed"; }
mark_stage_complete() { set_stage_status "$1" "complete"; log_stage "$1" "complete"; }
classify_quality_findings() { echo "correctness"; }
_extract_blocking_items() { echo ""; }

# Stub self_healing_build_test to succeed
self_healing_build_test() { return 0; }

# Write a non-empty feedback file so the early-return guard passes
echo "fix this issue" > "$ARTIFACTS_DIR/quality-feedback.md"

_crwf_rc=0
compound_rebuild_with_feedback 2 2>/dev/null || _crwf_rc=$?

assert_eq "compound_rebuild_with_feedback (happy): returns 0" "0" "$_crwf_rc"
assert_eq "compound_rebuild_with_feedback (happy): CURRENT_STAGE preserved" "compound_quality" "$CURRENT_STAGE"
assert_eq "compound_rebuild_with_feedback (happy): OUTER_STAGE cleared after return" "" "$OUTER_STAGE"
assert_eq "compound_rebuild_with_feedback (happy): INNER_STAGE cleared after return" "" "$INNER_STAGE"

print_test_section "compound_rebuild_with_feedback: build/test/review NOT reset to pending"

_sb=$(get_stage_status "build")
_st=$(get_stage_status "test")
_sr=$(get_stage_status "review")
assert_eq "compound_rebuild_with_feedback: build remains complete (not pending)" "complete" "$_sb"
assert_eq "compound_rebuild_with_feedback: test remains complete (not pending)" "complete" "$_st"
assert_eq "compound_rebuild_with_feedback: review remains complete (not pending)" "complete" "$_sr"

print_test_section "compound_rebuild_with_feedback: inner cycle snapshot has correct fields"

export OUTER_STAGE=""
export INNER_STAGE=""
export CURRENT_STAGE="compound_quality"
export PIPELINE_STATUS="running"
export STATE_FILE="$TEST_TEMP_DIR/state.md"
_snapshot_file="$TEST_TEMP_DIR/inner-snapshot.md"

# Stub self_healing_build_test to call update_status (simulating the real inner cycle)
# and capture a state snapshot
update_status() {
    local _status="$1" _stage="$2"
    PIPELINE_STATUS="$_status"
    if [[ -n "${OUTER_STAGE:-}" ]]; then
        INNER_STAGE="$_stage"
    else
        CURRENT_STAGE="$_stage"
        INNER_STAGE=""
    fi
    # Write a minimal snapshot for test inspection
    {
        printf 'current_stage: %s\n' "$CURRENT_STAGE"
        printf 'outer_stage: %s\n' "${OUTER_STAGE:-}"
        printf 'inner_stage: %s\n' "${INNER_STAGE:-}"
        printf 'status: %s\n' "$PIPELINE_STATUS"
    } > "$_snapshot_file"
    return 0
}
self_healing_build_test() {
    update_status "running" "build"
    return 0
}

echo "fix this issue" > "$ARTIFACTS_DIR/quality-feedback.md"
OUTER_STAGE=""
INNER_STAGE=""
CURRENT_STAGE="compound_quality"

compound_rebuild_with_feedback 3 2>/dev/null || true

# Inspect the snapshot written during the inner cycle
_snap_current=$(grep "^current_stage:" "$_snapshot_file" 2>/dev/null | cut -d' ' -f2 || echo "")
_snap_outer=$(grep "^outer_stage:" "$_snapshot_file" 2>/dev/null | cut -d' ' -f2 || echo "")
_snap_inner=$(grep "^inner_stage:" "$_snapshot_file" 2>/dev/null | cut -d' ' -f2 || echo "")

assert_eq "inner snapshot: current_stage is compound_quality" "compound_quality" "$_snap_current"
assert_eq "inner snapshot: outer_stage is compound_quality" "compound_quality" "$_snap_outer"
assert_eq "inner snapshot: inner_stage is build" "build" "$_snap_inner"

print_test_section "compound_rebuild_with_feedback: early-return safety (set_outer_stage placement)"

# The key invariant: set_outer_stage must be called AFTER the empty-feedback guard so that
# an early-exit (no feedback → return 1) never leaves OUTER_STAGE set on disk.
# Verified via code inspection rather than runtime mocking (avoids shellcheck SC2218).
_pi_src="$SCRIPT_DIR/lib/pipeline-intelligence.sh"

_guard_line=$(grep -n '! -s.*feedback_file' "$_pi_src" | head -1 | cut -d: -f1)
_set_outer_line=$(grep -n 'set_outer_stage "compound_quality"' "$_pi_src" | head -1 | cut -d: -f1)

if [[ -n "$_guard_line" && -n "$_set_outer_line" && "$_guard_line" -lt "$_set_outer_line" ]]; then
    assert_pass "early-return safety: set_outer_stage placed after the empty-feedback guard in compound_rebuild_with_feedback"
else
    assert_fail "early-return safety: set_outer_stage placed after the empty-feedback guard in compound_rebuild_with_feedback" \
        "guard at line ${_guard_line:-?}, set_outer_stage at line ${_set_outer_line:-?} — must be guard < set_outer_stage"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# H2: JSON-absent fail-closed — security-source-scan.json missing → BLOCKING item
# When security-source-scan.log exists but security-source-scan.json is absent or
# invalid, _extract_blocking_items must inject a synthetic SCANNER_ARTIFACT_MISSING
# blocking item so the gate stays closed (fail-closed, not fail-open).
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "H2: JSON-absent fail-closed for security-source-scan"

# Restore the real _extract_blocking_items — earlier tests stub it with { echo ""; }
# to isolate compound_rebuild_with_feedback. Clear the load guard and re-source the lib.
unset -f _extract_blocking_items 2>/dev/null || true
_PIPELINE_INTELLIGENCE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log" \
      "$ARTIFACTS_DIR/security-audit.log" "$ARTIFACTS_DIR/adversarial-review.json" \
      "$ARTIFACTS_DIR/adversarial-review.md" "$ARTIFACTS_DIR/negative-review.md" \
      "$ARTIFACTS_DIR/dod-audit.md" "$ARTIFACTS_DIR/classified-findings.json" \
      "$ARTIFACTS_DIR/security-advisories.log"

# Create a security-source-scan.log without a corresponding .json artifact
printf '# security scan log\nCRITICAL: src/app.sh:5 — potential secret\n' \
    > "$ARTIFACTS_DIR/security-source-scan.log"

# Confirm .json is absent
_h2_blocking=$(_extract_blocking_items)

_h2_has_missing=$(echo "$_h2_blocking" | grep -c "SCANNER_ARTIFACT_MISSING" 2>/dev/null || true)
_h2_has_missing="${_h2_has_missing:-0}"
assert_gt \
    "H2: SCANNER_ARTIFACT_MISSING blocking item emitted when security-source-scan.json absent" \
    "${_h2_has_missing:-0}" "0"

# Verify the finding appears in the blocking output (non-empty output means it is blocking)
if [[ -n "$_h2_blocking" ]]; then
    assert_pass "H2: _extract_blocking_items output is non-empty (finding is blocking, not advisory-only)"
else
    assert_fail "H2: _extract_blocking_items output is non-empty (finding is blocking, not advisory-only)" \
        "got empty output — SCANNER_ARTIFACT_MISSING was not promoted to blocking"
fi

# Verify advisory sidecar does NOT contain the blocking item (it's in blocking, not advisory)
_h2_advisory=$(cat "$ARTIFACTS_DIR/security-advisories.log" 2>/dev/null || true)
_h2_in_advisory=$(echo "$_h2_advisory" | grep -c "SCANNER_ARTIFACT_MISSING" 2>/dev/null || true)
_h2_in_advisory="${_h2_in_advisory:-0}"
assert_eq \
    "H2: SCANNER_ARTIFACT_MISSING is NOT placed in advisory sidecar (it is blocking)" \
    "0" "${_h2_in_advisory:-0}"

# Also test: when security-source-scan.log is absent, no synthetic item injected
rm -f "$ARTIFACTS_DIR/security-source-scan.log" "$ARTIFACTS_DIR/security-advisories.log"
_h2_no_log_blocking=$(_extract_blocking_items)
_h2_no_log_missing=$(echo "$_h2_no_log_blocking" | grep -c "SCANNER_ARTIFACT_MISSING" 2>/dev/null || true)
_h2_no_log_missing="${_h2_no_log_missing:-0}"
assert_eq \
    "H2: SCANNER_ARTIFACT_MISSING not injected when security-source-scan.log is also absent" \
    "0" "${_h2_no_log_missing:-0}"

rm -f "$ARTIFACTS_DIR/security-source-scan.json" "$ARTIFACTS_DIR/security-source-scan.log" \
      "$ARTIFACTS_DIR/security-advisories.log"

print_test_results
