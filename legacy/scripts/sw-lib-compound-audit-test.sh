#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  compound-audit test suite                                              ║
# ║  Tests adaptive cascade audit: agents, dedup, escalation, convergence   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: compound-audit Tests"

setup_test_env "sw-lib-compound-audit-test"
_test_cleanup_hook() { cleanup_test_env; }

mock_claude

# Source dependencies
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"
export LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"

_AUDIT_TRAIL_LOADED=""
source "$SCRIPT_DIR/lib/audit-trail.sh"
audit_init --issue 99 --goal "Test compound audit"

_COMPOUND_AUDIT_LOADED=""
source "$SCRIPT_DIR/lib/compound-audit.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_build_prompt
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_build_prompt"

# Test: logic auditor prompt contains specialization
result=$(compound_audit_build_prompt "logic" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Logic auditor prompt mentions bugs" "$result" "off-by-one"

# Test: integration auditor prompt contains specialization
result=$(compound_audit_build_prompt "integration" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Integration auditor prompt mentions wiring" "$result" "Wiring"

# Test: completeness auditor prompt mentions spec
result=$(compound_audit_build_prompt "completeness" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Completeness auditor prompt mentions spec" "$result" "spec"

# Test: prompt includes previous findings when provided
result=$(compound_audit_build_prompt "logic" "diff" "plan" '[{"description":"known bug"}]')
assert_contains "Prompt includes previous findings" "$result" "known bug"

# Test: prompt includes diff content
result=$(compound_audit_build_prompt "logic" "diff --git a/foo.sh" "plan" "[]")
assert_contains "Prompt includes diff" "$result" "diff --git a/foo.sh"

# Test: prompt includes plan summary
result=$(compound_audit_build_prompt "logic" "diff" "My plan summary here" "[]")
assert_contains "Prompt includes plan" "$result" "My plan summary here"

# Test: specialist prompts work
result=$(compound_audit_build_prompt "security" "diff" "plan" "[]")
assert_contains "Security prompt mentions injection" "$result" "injection"

result=$(compound_audit_build_prompt "error_handling" "diff" "plan" "[]")
assert_contains "Error handling prompt mentions catch" "$result" "catch"

# Test: test evidence section absent when test_evidence is empty
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "")
if echo "$result" | grep -q "Test Evidence"; then
    assert_fail "No Test Evidence section when empty"
else
    assert_pass "No Test Evidence section when empty"
fi

# Test: test evidence section present when test_evidence is non-empty
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "The full test suite was run by the pipeline BEFORE this audit and PASSED (exit 0).")
assert_contains "Test Evidence section present when evidence provided" "$result" "Test Evidence"

# Test: evidence content included in prompt
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "95 PASS | 0 FAIL")
assert_contains "Test evidence content included in prompt" "$result" "95 PASS | 0 FAIL"

# Test: CRITICAL guard present when evidence provided
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "The full test suite was run by the pipeline BEFORE this audit and PASSED (exit 0).")
assert_contains "Do NOT flag guard present in prompt" "$result" "Do NOT flag"

# Test: Output Format follows evidence section (no section bleed)
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "95 PASS | 0 FAIL")
assert_contains "Output Format section present after evidence" "$result" "Output Format"

# Test: Current File State section absent when file_contents is empty
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "" "")
if echo "$result" | grep -q "Current File State"; then
    assert_fail "No Current File State section when file_contents is empty"
else
    assert_pass "No Current File State section when file_contents is empty"
fi

# Test: Current File State section present when file_contents provided
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "" "### foo.sh (10 lines)")
assert_contains "Current File State section present" "$result" "Current File State"

# Test: VERIFICATION RULE injected with file_contents
assert_contains "VERIFICATION RULE present" "$result" "VERIFICATION RULE"

# Test: file content appears verbatim
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "" "### foo.sh (3 lines)"$'\n'"import FeedParsing")
assert_contains "File content included verbatim" "$result" "import FeedParsing"

# Test: Output Format section still present after file_contents injection
result=$(compound_audit_build_prompt "logic" "diff" "plan" "[]" "" "### foo.sh (3 lines)")
assert_contains "Output Format still present" "$result" "Output Format"

# Test: 5-arg backward compat (no file_contents)
result=$(compound_audit_build_prompt "logic" "diff --git a/x.sh" "plan" "[]" "95 PASS | 0 FAIL")
assert_contains "5-arg caller: diff still present" "$result" "diff --git a/x.sh"
assert_contains "5-arg caller: test evidence still present" "$result" "Test Evidence"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_parse_findings
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_parse_findings"

# Test: parses valid JSON findings
agent_output='{"findings":[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off-by-one","evidence":"i < n","suggestion":"Use i <= n"}]}'
result=$(compound_audit_parse_findings "$agent_output")
count=$(echo "$result" | jq 'length')
assert_eq "Parses one finding" "1" "$count"

# Test: extracts severity correctly
sev=$(echo "$result" | jq -r '.[0].severity')
assert_eq "Severity is high" "high" "$sev"

# Test: handles empty findings array
result=$(compound_audit_parse_findings '{"findings":[]}')
count=$(echo "$result" | jq 'length')
assert_eq "Empty findings returns empty array" "0" "$count"

# Test: handles malformed output gracefully
result=$(compound_audit_parse_findings "This is not JSON at all")
count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
assert_eq "Malformed output returns empty" "0" "$count"

# Test: handles output with markdown wrapping
result=$(compound_audit_parse_findings '```json
{"findings":[{"severity":"low","category":"completeness","file":"bar.sh","line":5,"description":"Missing test","evidence":"no test file","suggestion":"Add test"}]}
```')
count=$(echo "$result" | jq 'length')
assert_eq "Markdown-wrapped JSON parsed" "1" "$count"

# Test: handles multiple findings
agent_output='{"findings":[
  {"severity":"high","category":"logic","file":"a.sh","line":1,"description":"Bug 1","evidence":"x","suggestion":"y"},
  {"severity":"low","category":"logic","file":"b.sh","line":2,"description":"Bug 2","evidence":"x","suggestion":"y"}
]}'
result=$(compound_audit_parse_findings "$agent_output")
count=$(echo "$result" | jq 'length')
assert_eq "Parses multiple findings" "2" "$count"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_dedup_structural
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_dedup_structural"

# Test: same file + category + nearby lines = duplicate
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"foo.sh","line":12,"description":"Bug B","evidence":"code","suggestion":"fix"},
  {"severity":"medium","category":"integration","file":"bar.sh","line":50,"description":"Wiring gap","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Structural dedup merges nearby same-file same-category" "2" "$count"

# Test: different files are NOT deduped
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"bar.sh","line":10,"description":"Bug B","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Different files not deduped" "2" "$count"

# Test: different categories are NOT deduped
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"security","file":"foo.sh","line":10,"description":"Bug B","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Different categories not deduped" "2" "$count"

# Test: empty input returns empty
result=$(compound_audit_dedup_structural "[]")
count=$(echo "$result" | jq 'length')
assert_eq "Empty input returns empty" "0" "$count"

# Test: lines far apart are NOT deduped
findings='[
  {"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug A","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"foo.sh","line":100,"description":"Bug B","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_dedup_structural "$findings")
count=$(echo "$result" | jq 'length')
assert_eq "Distant lines not deduped" "2" "$count"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_escalate
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_escalate"

# Test: security keyword triggers security specialist
findings='[{"severity":"high","category":"logic","file":"auth.sh","line":10,"description":"Missing input validation allows injection","evidence":"eval $input","suggestion":"Sanitize"}]'
result=$(compound_audit_escalate "$findings")
assert_contains "Injection triggers security" "$result" "security"

# Test: error handling keyword triggers error_handling specialist
findings='[{"severity":"high","category":"integration","file":"foo.sh","line":10,"description":"Empty catch block silently swallows errors","evidence":".catch(() => {})","suggestion":"Log error"}]'
result=$(compound_audit_escalate "$findings")
assert_contains "Silent catch triggers error_handling" "$result" "error_handling"

# Test: no trigger keywords returns empty
findings='[{"severity":"low","category":"completeness","file":"readme.md","line":1,"description":"Missing section in docs","evidence":"no API section","suggestion":"Add it"}]'
result=$(compound_audit_escalate "$findings")
assert_eq "No triggers returns empty" "" "$result"

# Test: multiple triggers return unique list
findings='[
  {"severity":"high","category":"logic","file":"auth.sh","line":10,"description":"SQL injection in query","evidence":"code","suggestion":"fix"},
  {"severity":"high","category":"logic","file":"api.sh","line":20,"description":"Missing auth check allows bypass","evidence":"code","suggestion":"fix"}
]'
result=$(compound_audit_escalate "$findings")
# Should contain security but only once
count=$(echo "$result" | tr ' ' '\n' | grep -c "security" || true)
assert_eq "Security appears once even with multiple triggers" "1" "$count"

# Test: empty findings returns empty
result=$(compound_audit_escalate "[]")
assert_eq "Empty findings returns empty" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_converged
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_converged"

# Test: no critical/high findings = converged
result=$(compound_audit_converged "[]" "[]" 1 3)
assert_eq "No findings = converged" "no_criticals" "$result"

# Test: only low/medium findings = converged
new='[{"severity":"low","category":"logic","file":"foo.sh","line":1,"description":"Minor","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "Only low findings = converged" "no_criticals" "$result"

# Test: critical finding = NOT converged
new='[{"severity":"critical","category":"logic","file":"foo.sh","line":1,"description":"Major bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "Critical finding = not converged" "" "$result"

# Test: max cycles reached = converged regardless
new='[{"severity":"critical","category":"logic","file":"foo.sh","line":1,"description":"Major bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 3 3)
assert_eq "Max cycles = converged" "max_cycles" "$result"

# Test: all findings are duplicates of previous = converged (dup rate)
prev='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Bug","evidence":"x","suggestion":"y"}]'
new='[{"severity":"high","category":"logic","file":"foo.sh","line":11,"description":"Same bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "$prev" 1 3)
assert_eq "All dupes = converged" "dup_rate" "$result"

# Test: high finding = NOT converged
new='[{"severity":"high","category":"logic","file":"foo.sh","line":1,"description":"Important bug","evidence":"x","suggestion":"y"}]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "High finding = not converged" "" "$result"

# Test: mixed severity with critical = NOT converged
new='[
  {"severity":"low","category":"logic","file":"foo.sh","line":1,"description":"Minor","evidence":"x","suggestion":"y"},
  {"severity":"critical","category":"logic","file":"bar.sh","line":5,"description":"Major","evidence":"x","suggestion":"y"}
]'
result=$(compound_audit_converged "$new" "[]" 1 3)
assert_eq "Mixed with critical = not converged" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_run_cycle
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_run_cycle"

# Mock claude to return predictable findings based on stdin content
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Read stdin to get the prompt
input=$(cat)
if echo "$input" | grep -q "Logic Auditor"; then
    echo '{"findings":[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]}'
elif echo "$input" | grep -q "Integration Auditor"; then
    echo '{"findings":[]}'
elif echo "$input" | grep -q "Completeness Auditor"; then
    echo '{"findings":[{"severity":"low","category":"completeness","file":"bar.sh","line":5,"description":"Missing test","evidence":"no test","suggestion":"Add test"}]}'
else
    echo '{"findings":[]}'
fi
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Test: run_cycle with core agents returns merged findings
export COMPOUND_AUDIT_MODEL="haiku"
result=$(compound_audit_run_cycle "logic integration completeness" "diff content" "plan summary" "[]" 1)
count=$(echo "$result" | jq 'length')
assert_eq "Core cycle returns 2 findings" "2" "$count"

# Test: findings include correct categories
cats=$(echo "$result" | jq -r '.[].category' | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "Categories are logic and completeness" "completeness logic" "$cats"

# Test: audit trail events emitted
if [[ -f "$ARTIFACTS_DIR/pipeline-audit.jsonl" ]]; then
    cycle_start_count=$(grep -c '"compound.cycle_start"' "$ARTIFACTS_DIR/pipeline-audit.jsonl" || true)
    assert_gt "Cycle start event emitted" "$cycle_start_count" 0

    finding_count=$(grep -c '"compound.finding"' "$ARTIFACTS_DIR/pipeline-audit.jsonl" || true)
    assert_gt "Finding events emitted" "$finding_count" 0
else
    assert_fail "Audit trail JSONL exists" "File not found"
fi

# Test: single agent returns just its findings
result=$(compound_audit_run_cycle "logic" "diff content" "plan" "[]" 1)
count=$(echo "$result" | jq 'length')
assert_eq "Single agent returns its findings" "1" "$count"

# ═══════════════════════════════════════════════════════════════════════════════
# Convergence flag and deduped counting (Bug 1, 2, 3 regression tests)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade convergence flag and deduped counting"

# Test: compound_audit_converged returns reason when cycle >= max_cycles
result=$(compound_audit_converged "[]" "[]" 3 3)
if [[ -n "$result" ]]; then
    assert_pass "converged at max_cycles returns reason"
else
    assert_fail "converged at max_cycles returns reason" "Expected non-empty reason, got empty"
fi

# Test: compound_audit_converged returns reason on empty new findings (plateau)
prev='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"x","suggestion":"fix"}]'
result=$(compound_audit_converged "[]" "$prev" 2 5)
if [[ -n "$result" ]]; then
    assert_pass "converged on empty new findings returns reason"
else
    assert_fail "converged on empty new findings returns reason" "Expected non-empty reason, got empty"
fi

# Test: compound_audit_converged returns empty string when not yet converged
result=$(compound_audit_converged '[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"New bug","evidence":"x","suggestion":"fix"}]' "[]" 1 5)
if [[ -z "$result" ]]; then
    assert_pass "not converged returns empty string"
else
    assert_fail "not converged returns empty string" "Expected empty, got: $result"
fi

# Test: dedup removes exact duplicates across cycles
finding='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"x","suggestion":"fix"}]'
doubled=$(echo "$finding" "$finding" | jq -s '.[0] + .[1]')
deduped=$(compound_audit_dedup_structural "$doubled")
count=$(echo "$deduped" | jq 'length')
assert_eq "dedup removes exact duplicate across cycles" "1" "$count"

# Test: dedup keeps genuinely different findings
finding_a='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"x","suggestion":"fix"}]'
finding_b='[{"severity":"high","category":"security","file":"foo.sh","line":10,"description":"SQL injection","evidence":"y","suggestion":"sanitize"}]'
combined=$(echo "$finding_a" "$finding_b" | jq -s '.[0] + .[1]')
deduped=$(compound_audit_dedup_structural "$combined")
count=$(echo "$deduped" | jq 'length')
assert_eq "dedup keeps different-category findings on same line" "2" "$count"

# Test: convergence count uses variable length, not file (dedup prevents inflation)
# Simulate two cycles with the same finding — after dedup, count should be 1
finding='[{"severity":"critical","category":"logic","file":"foo.sh","line":5,"description":"Null deref","evidence":"ptr","suggestion":"check null"}]'
accumulated=$(echo "$finding" "$finding" | jq -s '.[0] + .[1]')
if type compound_audit_dedup_structural >/dev/null 2>&1; then
    accumulated=$(compound_audit_dedup_structural "$accumulated") || true
fi
crit_count=$(echo "$accumulated" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
assert_eq "deduped accumulation counts 1 not 2 for convergence" "1" "$crit_count"

# ═══════════════════════════════════════════════════════════════════════════════
# Stale findings after rebuild (issue #153 regression test)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stale findings after rebuild"

# Test: findings with shifted line numbers defeat structural dedup
# Simulates what happens when code is rebuilt and line numbers shift by >5
pre_rebuild='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one in loop","evidence":"i < n","suggestion":"Use <="}]'
post_rebuild='[{"severity":"high","category":"logic","file":"foo.sh","line":18,"description":"Off by one in loop","evidence":"i < n","suggestion":"Use <="}]'
combined=$(jq -n --argjson a "$pre_rebuild" --argjson b "$post_rebuild" '$a + $b')
deduped=$(compound_audit_dedup_structural "$combined")
count=$(echo "$deduped" | jq 'length')
# Line shift of 8 defeats the ±5 window — dedup keeps both, proving stale findings cause duplicates
assert_eq "shifted lines (>5) defeat structural dedup" "2" "$count"

# Test: clearing findings after rebuild prevents false duplicates
# After rebuild, _cascade_all_findings should be reset to "[]"
# so the next cycle starts fresh — no stale line numbers to conflict with
cleared="[]"
post_rebuild_fresh='[{"severity":"high","category":"logic","file":"foo.sh","line":18,"description":"Off by one in loop","evidence":"i < n","suggestion":"Use <="}]'
combined_fresh=$(jq -n --argjson a "$cleared" --argjson b "$post_rebuild_fresh" '$a + $b')
deduped_fresh=$(compound_audit_dedup_structural "$combined_fresh")
count_fresh=$(echo "$deduped_fresh" | jq 'length')
assert_eq "cleared findings after rebuild yields clean cycle" "1" "$count_fresh"

# Test: convergence detection works correctly after findings reset
# With cleared findings, convergence should detect no_criticals when no new critical/high found
converge_result=$(compound_audit_converged "[]" "[]" 2 5)
assert_eq "converged after reset with no new findings" "no_criticals" "$converge_result"

# ═══════════════════════════════════════════════════════════════════════════════
# Integration test: simulate full rebuild + cascade convergence (issue #153)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "infinite loop prevention (integration)"

# Simulate the full scenario that caused infinite loops:
# 1. Cycle 1: agent finds issue X at line 10
# 2. Rebuild modifies code — line 10 moves to line 18
# 3. Cycle 2 (WITHOUT fix): agent re-reports issue X at line 18, dedup fails → loop
# 3. Cycle 2 (WITH fix): findings cleared after rebuild, agent reports at line 18, converges

max_sim_cycles=5
sim_findings="[]"
sim_converged=""

# Cycle 1: initial finding
cycle1_new='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]'
sim_findings=$(jq -n --argjson a "$sim_findings" --argjson b "$cycle1_new" '$a + $b')
sim_findings=$(compound_audit_dedup_structural "$sim_findings")
c1_converge=$(compound_audit_converged "$cycle1_new" "[]" 1 "$max_sim_cycles")
assert_eq "cycle 1: not converged (critical/high found)" "" "$c1_converge"

# Simulate rebuild: code changed, line 10 → line 18
# WITH FIX: clear findings (as pipeline-intelligence.sh now does)
sim_findings="[]"
sim_converged=false

# Cycle 2: agent finds same issue at new line, but findings are clear
cycle2_new='[{"severity":"high","category":"logic","file":"foo.sh","line":18,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]'
sim_findings=$(jq -n --argjson a "$sim_findings" --argjson b "$cycle2_new" '$a + $b')
sim_findings=$(compound_audit_dedup_structural "$sim_findings")
c2_converge=$(compound_audit_converged "$cycle2_new" "[]" 2 "$max_sim_cycles")
# After clearing, prev_findings is empty, so it checks crit/high count — still has high
assert_eq "cycle 2 after reset: not converged (new high finding)" "" "$c2_converge"

# Cycle 3: no new findings (rebuild fixed the issue)
cycle3_new="[]"
c3_converge=$(compound_audit_converged "$cycle3_new" "$sim_findings" 3 "$max_sim_cycles")
assert_eq "cycle 3: converged (no new findings)" "no_criticals" "$c3_converge"

# Verify: the loop terminated in ≤ max_sim_cycles
assert_eq "loop converged within max cycles" "no_criticals" "$c3_converge"

# Counter-test: WITHOUT the fix (stale findings preserved), dedup fails → never converges
stale_accumulated='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]'
shifted_new='[{"severity":"high","category":"logic","file":"foo.sh","line":18,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]'
stale_converge=$(compound_audit_converged "$shifted_new" "$stale_accumulated" 2 "$max_sim_cycles")
# Line shift of 8 > ±5 window, so not a dup; has crit/high → not converged
assert_eq "without fix: shifted findings don't converge (proves bug)" "" "$stale_converge"

# Test: _cascade_converged=false (not empty string) after reset is valid for loop re-entry
# The while loop condition checks [[ "$_cascade_converged" != "true" ]]
# so both "false" and "" would work, but "false" is unambiguous
test_converged_val=false
if [[ "$test_converged_val" != "true" ]]; then
    assert_eq "false is valid loop re-entry state" "pass" "pass"
else
    assert_eq "false should allow loop re-entry" "pass" "fail"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_collect_file_contents
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_collect_file_contents"

_setup_collect_repo() {
    local dir="$TEST_TEMP_DIR/collect-repo-$1"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q -b main
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
        # Create a feature branch so diff main...HEAD shows changes
        git checkout -q -b feature
    )
    echo "$dir"
}

# Test 1: empty when no changes
_repo=$(_setup_collect_repo "1")
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null || true)
if [[ -z "$result" ]]; then
    assert_pass "Returns empty when no changed files"
else
    assert_fail "Returns empty when no changed files" "got: $result"
fi

# Test 2: fenced block with content
_repo=$(_setup_collect_repo "2")
(
    cd "$_repo"
    printf 'import FeedParsing\n# line 2\n' > foo.sh
    git add foo.sh
    git -c user.email=t@t -c user.name=t commit -q -m add
    echo "# line 3" >> foo.sh
    git add foo.sh
    git -c user.email=t@t -c user.name=t commit -q -m modify
)
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null)
assert_contains "Fenced block header present" "$result" "### foo.sh"
assert_contains "Fenced block content present" "$result" "import FeedParsing"

# Test 3: 800-line skip marker
_repo=$(_setup_collect_repo "3")
(
    cd "$_repo"
    seq 1 801 | awk '{print "line " $1}' > big.sh
    git add big.sh
    git -c user.email=t@t -c user.name=t commit -q -m add
    echo "# change" >> big.sh
    git add big.sh
    git -c user.email=t@t -c user.name=t commit -q -m modify
)
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null)
assert_contains "800-line skip marker present" "$result" "exceeds 800-line limit"

# Test 4: 40k char budget exhausted
_repo=$(_setup_collect_repo "4")
(
    cd "$_repo"
    python3 -c "print('x' * 30000)" > a.sh
    python3 -c "print('y' * 30000)" > b.sh
    git add a.sh b.sh
    git -c user.email=t@t -c user.name=t commit -q -m add
    echo "# change" >> a.sh && echo "# change" >> b.sh
    git add a.sh b.sh
    git -c user.email=t@t -c user.name=t commit -q -m modify
)
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null)
assert_contains "Budget exhausted marker present" "$result" "char budget exhausted at 40000"

# Test 5: deleted file marker
_repo=$(_setup_collect_repo "5")
(
    cd "$_repo"
    # On main: add a file
    git checkout -q main
    echo "content" > del.sh
    git add del.sh
    git -c user.email=t@t -c user.name=t commit -q -m "add on main"
    # On feature: create the file from main then delete it (simulating removal)
    git checkout -q feature
    git pull -q origin main 2>/dev/null || git merge -q main 2>/dev/null || {
        # Manual merge if automated merge fails
        git reset -q --hard main
    }
    git rm -q del.sh
    git -c user.email=t@t -c user.name=t commit -q -m "delete on feature"
)
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null)
assert_contains "Deleted file marker present" "$result" "(deleted)"

# Test 6: real newlines in output (not literal \n)
_repo=$(_setup_collect_repo "6")
(
    cd "$_repo"
    printf 'import FeedParsing\n' > foo.sh
    git add foo.sh
    git -c user.email=t@t -c user.name=t commit -q -m add
    echo "# change" >> foo.sh
    git add foo.sh
    git -c user.email=t@t -c user.name=t commit -q -m modify
)
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null)
if printf '%s' "$result" | grep -q '^### foo.sh'; then
    assert_pass "Output contains real newlines"
else
    assert_fail "Output contains real newlines" "first line: $(printf '%s' "$result" | head -1)"
fi

# Test 7: renamed files handled via --no-renames (delete+add pair)
_repo=$(_setup_collect_repo "7")
(
    cd "$_repo"
    # On main: add the original file
    git checkout -q main
    echo "content" > old.sh
    git add old.sh
    git -c user.email=t@t -c user.name=t commit -q -m "add old.sh on main"
    # On feature: sync from main then rename
    git checkout -q feature
    git reset -q --hard main
    git mv old.sh new.sh
    git -c user.email=t@t -c user.name=t commit -q -m rename
)
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 40000 2>/dev/null)
assert_contains "Renamed file: old path marked deleted" "$result" "old.sh (deleted)"
assert_contains "Renamed file: new path has content" "$result" "### new.sh"

# Test 8: files beyond the 5000-line diff cap are still enumerated
# This is the headline regression test for issue #341: proves the collector uses
# git --numstat (not the truncated $_cascade_diff) so later files are covered.
_repo=$(_setup_collect_repo "8")
(
    cd "$_repo"
    i=1
    while [[ $i -le 20 ]]; do
        seq 1 300 | awk -v n="$i" '{print "file " n " line " $1}' > "file-${i}.sh"
        i=$((i + 1))
    done
    git add .
    git -c user.email=t@t -c user.name=t commit -q -m add-all
    i=1
    while [[ $i -le 20 ]]; do
        echo "# modified" >> "file-${i}.sh"
        i=$((i + 1))
    done
    git add .
    git -c user.email=t@t -c user.name=t commit -q -m modify-all
)
# 20 × 300-line files = 6000+ lines combined diff (beyond 5000-line head cap).
# With a generous budget all files should be enumerated, including file-20.sh.
result=$(cd "$_repo" && BASE_BRANCH=main compound_audit_collect_file_contents 200000 2>/dev/null)
assert_contains "Many-file coverage: first file present" "$result" "### file-1.sh"
assert_contains "Many-file coverage: 20th file still present" "$result" "### file-20.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_verify_findings
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_verify_findings"

# Helper: create a minimal git repo for verify_findings tests
_setup_vf_repo() {
    local dir="$TEST_TEMP_DIR/vf-repo-$1"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q -b main
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    )
    echo "$dir"
}

# Test 1 — Positive drop: capitalized import exists in cited file → drop
_repo=$(_setup_vf_repo "1")
(
    cd "$_repo"
    printf 'import FeedParsing\n# other code\n' > foo.swift
    git add foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"critical","category":"integration","file":"foo.swift","line":1,"description":"missing import FeedParsing","evidence":"","suggestion":"add import"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Positive drop: hallucinated import finding removed" "0" "$count"

# Test 2 — Wrong-file scope: symbol in bar.swift but finding cites foo.swift → keep
_repo=$(_setup_vf_repo "2")
(
    cd "$_repo"
    printf 'import FeedParsing\n' > bar.swift
    printf '# unrelated\n' > foo.swift
    git add bar.swift foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"critical","category":"integration","file":"foo.swift","line":1,"description":"missing import FeedParsing","evidence":"","suggestion":"add import"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Wrong-file scope: finding kept when symbol absent from cited file" "1" "$count"

# Test 3 — Word-boundary safety: FooBarManager exists, not Foo → keep
_repo=$(_setup_vf_repo "3")
(
    cd "$_repo"
    printf 'class FooBarManager {}\n' > foo.swift
    git add foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"high","category":"logic","file":"foo.swift","line":1,"description":"cannot find Foo in scope","evidence":"","suggestion":"import it"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Word boundary: FooBarManager does not satisfy missing Foo claim" "1" "$count"

# Test 4 — Lowercase quoted Swift drop: func fetchFeed exists, finding says cannot find 'fetchFeed' → drop
_repo=$(_setup_vf_repo "4")
(
    cd "$_repo"
    printf 'func fetchFeed() { return [] }\n' > foo.swift
    git add foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"critical","category":"integration","file":"foo.swift","line":1,"description":"cannot find '\''fetchFeed'\'' in scope","evidence":"","suggestion":"define it"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Lowercase quoted Swift: hallucinated find-quote finding dropped" "0" "$count"

# Test 5 — Go-style undefined: drop: func parseBody exists → drop
_repo=$(_setup_vf_repo "5")
(
    cd "$_repo"
    printf 'func parseBody() error { return nil }\n' > foo.go
    git add foo.go
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"critical","category":"integration","file":"foo.go","line":1,"description":"undefined: parseBody","evidence":"","suggestion":"define it"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Go-style undefined: hallucinated finding dropped" "0" "$count"

# Test 6 — Lowercase no-symbol pass-through: "missing function parseXML" doesn't match absence pattern
_findings='[{"severity":"medium","category":"logic","file":"foo.sh","line":5,"description":"missing function parseXML","evidence":"","suggestion":"add it"}]'
result=$(compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "No-symbol pass-through: absence pattern does not match 'missing function'" "1" "$count"

# Test 7 — Tight absence pattern: "Missing null check for import stream" must NOT be treated as symbol-absence
_findings='[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Missing null check for import stream","evidence":"","suggestion":"add null check"}]'
result=$(compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Tight pattern: 'Missing null check for import stream' is kept (not a symbol claim)" "1" "$count"

# Test 8 — Path normalization: ./foo.swift normalizes to foo.swift → drop
_repo=$(_setup_vf_repo "8")
(
    cd "$_repo"
    printf 'import FeedParsing\n' > foo.swift
    git add foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"critical","category":"integration","file":"./foo.swift","line":1,"description":"missing import FeedParsing","evidence":"","suggestion":"add import"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Path normalization: ./foo.swift strips to foo.swift and drops correctly" "0" "$count"

# Test 9 — Fail-open on unreadable file: nonexistent.swift → keep
_repo=$(_setup_vf_repo "9")
_findings='[{"severity":"critical","category":"integration","file":"nonexistent.swift","line":1,"description":"missing import FeedParsing","evidence":"","suggestion":"add import"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Fail-open: unreadable file keeps finding" "1" "$count"

# Test 10 — Mixed array: 3 findings, 1 drop, 2 keep; accumulator correct
_repo=$(_setup_vf_repo "10")
(
    cd "$_repo"
    printf 'import FeedParsing\n' > foo.swift
    git add foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[
  {"severity":"high","category":"logic","file":"bar.sh","line":5,"description":"off-by-one error in loop","evidence":"i <= len","suggestion":"use <"},
  {"severity":"critical","category":"integration","file":"foo.swift","line":1,"description":"missing import FeedParsing","evidence":"","suggestion":"add import"},
  {"severity":"medium","category":"completeness","file":"baz.sh","line":20,"description":"spec requirement unimplemented","evidence":"TODO","suggestion":"implement"}
]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings")
count=$(echo "$result" | jq 'length')
assert_eq "Mixed array: 2 of 3 findings survive after drop" "2" "$count"
assert_contains "Mixed array: first real finding preserved" "$result" "off-by-one"
assert_contains "Mixed array: third real finding preserved" "$result" "spec requirement"

# Test 11 — Regex metachar safety: $foo symbol must not crash verifier
_repo=$(_setup_vf_repo "11")
(
    cd "$_repo"
    printf 'some code\n' > foo.sh
    git add foo.sh
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"high","category":"logic","file":"foo.sh","line":1,"description":"cannot find $foo in scope","evidence":"","suggestion":"fix"}]'
result=$(cd "$_repo" && compound_audit_verify_findings "$_findings" 2>/dev/null)
count=$(echo "$result" | jq 'length')
assert_eq "Metachar safety: \$foo in description does not crash verifier" "1" "$count"

# Test 12 — Audit event payload: drop event emitted with symbol= and file= fields
_repo=$(_setup_vf_repo "12")
(
    cd "$_repo"
    printf 'import FeedParsing\n' > foo.swift
    git add foo.swift
    git -c user.email=t@t -c user.name=t commit -q -m add
)
_findings='[{"severity":"critical","category":"integration","file":"foo.swift","line":1,"description":"missing import FeedParsing","evidence":"","suggestion":"add import"}]'
(cd "$_repo" && compound_audit_verify_findings "$_findings") >/dev/null
_event_line=$(grep "false_positive_dropped" "$ARTIFACTS_DIR/pipeline-audit.jsonl" 2>/dev/null | tail -1 || true)
assert_contains "Audit event payload: symbol field present" "$_event_line" '"symbol":"FeedParsing"'
assert_contains "Audit event payload: file field present" "$_event_line" '"file":"foo.swift"'

print_test_results
