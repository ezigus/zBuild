# Compound Audit Cascade — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the one-shot compound_quality stage with an adaptive multi-agent cascade that iteratively probes for bugs until confidence is high.

**Architecture:** New library `compound-audit.sh` with four functions (run_cycle, dedup, escalate, converged). Integrates into existing `stage_compound_quality()` in `pipeline-intelligence.sh`. Agents run as parallel `claude -p --model haiku` calls. Dedup uses structural matching + haiku LLM judge. Convergence stops on no new critical/high OR >98% dup rate OR max_cycles.

**Tech Stack:** Bash 3.2, `claude -p`, `jq`, audit-trail.sh JSONL events

---

### Task 1: Compound Audit Library — Core Scaffolding + Tests

**Files:**
- Create: `scripts/lib/compound-audit.sh`
- Create: `scripts/sw-lib-compound-audit-test.sh`

**Step 1: Write the test file scaffold**

```bash
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
trap cleanup_test_env EXIT

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
assert_contains "Logic auditor prompt mentions bugs" "$result" "logic error"

# Test: integration auditor prompt contains specialization
result=$(compound_audit_build_prompt "integration" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Integration auditor prompt mentions wiring" "$result" "wiring"

# Test: completeness auditor prompt mentions spec
result=$(compound_audit_build_prompt "completeness" "diff --git a/foo.sh" "plan summary" "[]")
assert_contains "Completeness auditor prompt mentions spec" "$result" "spec"

# Test: prompt includes previous findings when provided
result=$(compound_audit_build_prompt "logic" "diff" "plan" '[{"description":"known bug"}]')
assert_contains "Prompt includes previous findings" "$result" "known bug"

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

print_summary
```

**Step 2: Write the library scaffold with prompt builder and parser**

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  compound-audit — Adaptive multi-agent audit cascade                    ║
# ║                                                                         ║
# ║  Runs specialized audit agents in parallel, deduplicates findings,      ║
# ║  escalates to specialists when needed, and converges when confidence    ║
# ║  is high. All functions fail-open with || return 0.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_COMPOUND_AUDIT_LOADED:-}" ]] && return 0
_COMPOUND_AUDIT_LOADED=1

# ─── Agent prompt templates ────────────────────────────────────────────────
# Each agent gets the same context but a specialized lens.

_COMPOUND_AGENT_PROMPTS_logic="You are a Logic Auditor. Focus ONLY on:
- Control flow bugs, off-by-one errors, wrong conditions
- Algorithm errors, incorrect logic, null/undefined paths
- Race conditions, state management bugs
- Edge cases in arithmetic or string operations
Do NOT report style issues, missing features, or integration problems."

_COMPOUND_AGENT_PROMPTS_integration="You are an Integration Auditor. Focus ONLY on:
- Missing imports, broken call chains, unconnected components
- Mismatched interfaces between modules
- Functions called with wrong arguments or missing arguments
- Wiring gaps where new code isn't connected to existing code
Do NOT report logic bugs, style issues, or missing features."

_COMPOUND_AGENT_PROMPTS_completeness="You are a Completeness Auditor. Focus ONLY on:
- Spec vs. implementation gaps (does the code do what the plan says?)
- Missing test coverage for new functionality
- TODO/FIXME/placeholder code left behind
- Partial implementations (feature started but not finished)
Do NOT report logic bugs, style issues, or integration problems."

_COMPOUND_AGENT_PROMPTS_security="You are a Security Auditor. Focus ONLY on:
- Command injection, path traversal, input validation gaps
- Credential/secret exposure in code or logs
- Authentication/authorization bypass paths
- OWASP top 10 vulnerability patterns
Do NOT report non-security issues."

_COMPOUND_AGENT_PROMPTS_error_handling="You are an Error Handling Auditor. Focus ONLY on:
- Silent error swallowing (empty catch blocks, ignored return codes)
- Missing error paths (what happens when X fails?)
- Inconsistent error handling patterns
- Unchecked return values from external commands
Do NOT report non-error-handling issues."

_COMPOUND_AGENT_PROMPTS_performance="You are a Performance Auditor. Focus ONLY on:
- O(n^2) or worse patterns in loops
- Unbounded memory allocation or file reads
- Missing pagination or streaming for large data
- Repeated expensive operations that could be cached
Do NOT report non-performance issues."

_COMPOUND_AGENT_PROMPTS_edge_case="You are an Edge Case Auditor. Focus ONLY on:
- Zero-length inputs, empty strings, empty arrays
- Maximum/minimum boundary values
- Unicode, special characters, newlines in data
- Concurrent access, timing-dependent behavior
Do NOT report non-edge-case issues."

# ─── compound_audit_build_prompt ───────────────────────────────────────────
# Builds the full prompt for a specific agent type.
#
# Usage: compound_audit_build_prompt "logic" "$diff" "$plan" "$prev_findings_json"
compound_audit_build_prompt() {
    local agent_type="$1"
    local diff="$2"
    local plan_summary="$3"
    local prev_findings="$4"

    # Get agent-specific instructions
    local varname="_COMPOUND_AGENT_PROMPTS_${agent_type}"
    local specialization="${!varname:-"You are a code auditor. Review the changes for issues."}"

    cat <<EOF
${specialization}

## Code Changes (cumulative diff)
\`\`\`
${diff}
\`\`\`

## Implementation Plan/Spec
${plan_summary}

## Previously Found Issues (do NOT repeat these)
${prev_findings}

## Output Format
Return ONLY valid JSON (no markdown, no explanation):
{"findings":[{"severity":"critical|high|medium|low","category":"${agent_type}","file":"path/to/file","line":0,"description":"One sentence","evidence":"The specific code","suggestion":"How to fix"}]}

If no issues found, return: {"findings":[]}
EOF
}

# ─── compound_audit_parse_findings ─────────────────────────────────────────
# Parses agent output into a findings array. Handles malformed output.
#
# Usage: compound_audit_parse_findings "$agent_stdout"
# Output: JSON array of findings (or empty array on failure)
compound_audit_parse_findings() {
    local raw_output="$1"

    # Strip markdown code fences if present
    local cleaned
    cleaned=$(echo "$raw_output" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\r')

    # Try to extract findings array
    local findings
    findings=$(echo "$cleaned" | jq -r '.findings // []' 2>/dev/null) || findings="[]"

    # Validate it's actually an array
    if echo "$findings" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$findings"
    else
        echo "[]"
    fi
}
```

**Step 3: Run tests to verify they pass**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: All tests pass (prompt builder returns correct content, parser handles valid/invalid/wrapped JSON)

**Step 4: Commit**

```bash
git add scripts/lib/compound-audit.sh scripts/sw-lib-compound-audit-test.sh
git commit -m "feat: compound audit library scaffold with prompt builder and parser"
```

---

### Task 2: Deduplication — Structural + LLM Judge

**Files:**
- Modify: `scripts/lib/compound-audit.sh`
- Modify: `scripts/sw-lib-compound-audit-test.sh`

**Step 1: Add dedup tests to test file**

Append to `scripts/sw-lib-compound-audit-test.sh` (before `print_summary`):

```bash
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
```

**Step 2: Run tests to verify they fail**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: FAIL — `compound_audit_dedup_structural: command not found`

**Step 3: Implement structural dedup**

Add to `scripts/lib/compound-audit.sh`:

```bash
# ─── compound_audit_dedup_structural ───────────────────────────────────────
# Tier 1 dedup: same file + same category + lines within 5 = duplicate.
# Keeps the first (highest severity) finding in each group.
#
# Usage: compound_audit_dedup_structural "$findings_json_array"
# Output: Deduplicated JSON array
compound_audit_dedup_structural() {
    local findings="$1"

    [[ -z "$findings" || "$findings" == "[]" ]] && { echo "[]"; return 0; }

    # Use jq to group by file+category, then within each group merge findings
    # whose lines are within 5 of each other
    echo "$findings" | jq '
      # Sort by severity priority (critical first) then by line
      def sev_order: if . == "critical" then 0 elif . == "high" then 1
        elif . == "medium" then 2 else 3 end;

      sort_by([(.severity | sev_order), .line]) |

      # Group by file + category
      group_by([.file, .category]) |

      # Within each group, merge findings with lines within 5
      map(
        reduce .[] as $item ([];
          if length == 0 then [$item]
          elif (. | last | .line) and $item.line and
               (($item.line - (. | last | .line)) | fabs) <= 5
          then .  # Skip duplicate (nearby line, same file+category)
          else . + [$item]
          end
        )
      ) | flatten
    ' 2>/dev/null || echo "$findings"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: All structural dedup tests pass

**Step 5: Commit**

```bash
git add scripts/lib/compound-audit.sh scripts/sw-lib-compound-audit-test.sh
git commit -m "feat: structural dedup for compound audit findings"
```

---

### Task 3: Escalation Logic

**Files:**
- Modify: `scripts/lib/compound-audit.sh`
- Modify: `scripts/sw-lib-compound-audit-test.sh`

**Step 1: Add escalation tests**

Append to test file (before `print_summary`):

```bash
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
```

**Step 2: Run tests to verify they fail**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: FAIL — `compound_audit_escalate: command not found`

**Step 3: Implement escalation**

Add to `scripts/lib/compound-audit.sh`:

```bash
# ─── Escalation trigger keywords ──────────────────────────────────────────
_COMPOUND_TRIGGERS_security="injection|auth|secret|credential|permission|bypass|xss|csrf|traversal|sanitiz"
_COMPOUND_TRIGGERS_error_handling="catch|swallow|silent|ignore.*error|missing.*error|unchecked|unhandled"
_COMPOUND_TRIGGERS_performance="O(n|loop.*loop|unbounded|pagination|cache|memory.*leak|quadratic"
_COMPOUND_TRIGGERS_edge_case="boundary|empty.*input|null.*check|zero.*length|unicode|concurrent|race"

# ─── compound_audit_escalate ──────────────────────────────────────────────
# Scans findings for trigger keywords, returns space-separated specialist list.
#
# Usage: compound_audit_escalate "$findings_json_array"
# Output: Space-separated specialist names (e.g., "security error_handling")
compound_audit_escalate() {
    local findings="$1"

    [[ -z "$findings" || "$findings" == "[]" ]] && return 0

    # Flatten all finding text for keyword scanning
    local all_text
    all_text=$(echo "$findings" | jq -r '.[].description + " " + .[].evidence + " " + .[].file' 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 0

    local specialists=""
    local spec
    for spec in security error_handling performance edge_case; do
        local varname="_COMPOUND_TRIGGERS_${spec}"
        local pattern="${!varname:-}"
        if [[ -n "$pattern" ]] && echo "$all_text" | grep -qEi "$pattern" 2>/dev/null; then
            specialists="${specialists:+${specialists} }${spec}"
        fi
    done

    echo "$specialists"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: All escalation tests pass

**Step 5: Commit**

```bash
git add scripts/lib/compound-audit.sh scripts/sw-lib-compound-audit-test.sh
git commit -m "feat: trigger-based escalation for compound audit"
```

---

### Task 4: Convergence Detection

**Files:**
- Modify: `scripts/lib/compound-audit.sh`
- Modify: `scripts/sw-lib-compound-audit-test.sh`

**Step 1: Add convergence tests**

Append to test file (before `print_summary`):

```bash
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
```

**Step 2: Run tests to verify they fail**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: FAIL — `compound_audit_converged: command not found`

**Step 3: Implement convergence**

Add to `scripts/lib/compound-audit.sh`:

```bash
# ─── compound_audit_converged ─────────────────────────────────────────────
# Checks stop conditions for the cascade loop.
#
# Usage: compound_audit_converged "$new_findings" "$all_prev_findings" $cycle $max_cycles
# Output: Reason string if converged ("no_criticals", "dup_rate", "max_cycles"), empty if not
compound_audit_converged() {
    local new_findings="$1"
    local prev_findings="$2"
    local cycle="$3"
    local max_cycles="$4"

    # Hard cap: max cycles reached
    if [[ "$cycle" -ge "$max_cycles" ]]; then
        echo "max_cycles"
        return 0
    fi

    # No findings at all = converged
    local new_count
    new_count=$(echo "$new_findings" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$new_count" -eq 0 ]]; then
        echo "no_criticals"
        return 0
    fi

    # Check for critical/high in new findings
    local crit_high_count
    crit_high_count=$(echo "$new_findings" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")

    # If previous findings exist, check duplicate rate via structural match
    local prev_count
    prev_count=$(echo "$prev_findings" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$prev_count" -gt 0 && "$new_count" -gt 0 ]]; then
        # Count how many new findings structurally match previous ones
        local dup_count=0
        local i=0
        while [[ "$i" -lt "$new_count" ]]; do
            local nf nc nl
            nf=$(echo "$new_findings" | jq -r ".[$i].file // \"\"" 2>/dev/null)
            nc=$(echo "$new_findings" | jq -r ".[$i].category // \"\"" 2>/dev/null)
            nl=$(echo "$new_findings" | jq -r ".[$i].line // 0" 2>/dev/null)

            # Check if any previous finding matches file+category+nearby line
            local match
            match=$(echo "$prev_findings" | jq --arg f "$nf" --arg c "$nc" --argjson l "$nl" \
                '[.[] | select(.file == $f and .category == $c and ((.line // 0) - $l | fabs) <= 5)] | length' 2>/dev/null || echo "0")
            [[ "$match" -gt 0 ]] && dup_count=$((dup_count + 1))
            i=$((i + 1))
        done

        # If all findings are duplicates, converged
        if [[ "$dup_count" -eq "$new_count" ]]; then
            echo "dup_rate"
            return 0
        fi
    fi

    # No critical/high = converged
    if [[ "$crit_high_count" -eq 0 ]]; then
        echo "no_criticals"
        return 0
    fi

    # Not converged
    echo ""
    return 0
}
```

**Step 4: Run tests to verify they pass**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: All convergence tests pass

**Step 5: Commit**

```bash
git add scripts/lib/compound-audit.sh scripts/sw-lib-compound-audit-test.sh
git commit -m "feat: convergence detection for compound audit cascade"
```

---

### Task 5: Run Cycle — Parallel Agent Execution

**Files:**
- Modify: `scripts/lib/compound-audit.sh`
- Modify: `scripts/sw-lib-compound-audit-test.sh`

**Step 1: Add run_cycle tests**

Append to test file (before `print_summary`):

```bash
# ═══════════════════════════════════════════════════════════════════════════════
# compound_audit_run_cycle
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compound_audit_run_cycle"

# Mock claude to return predictable findings
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Return findings based on prompt content
if echo "$*" | grep -q "Logic Auditor"; then
    echo '{"findings":[{"severity":"high","category":"logic","file":"foo.sh","line":10,"description":"Off by one","evidence":"i < n","suggestion":"Use <="}]}'
elif echo "$*" | grep -q "Integration Auditor"; then
    echo '{"findings":[]}'
elif echo "$*" | grep -q "Completeness Auditor"; then
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
```

**Step 2: Run tests to verify they fail**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: FAIL — `compound_audit_run_cycle: command not found`

**Step 3: Implement run_cycle**

Add to `scripts/lib/compound-audit.sh`:

```bash
# ─── compound_audit_run_cycle ─────────────────────────────────────────────
# Runs multiple agents in parallel and collects their findings.
#
# Usage: compound_audit_run_cycle "logic integration completeness" "$diff" "$plan" "$prev_findings" $cycle
# Output: Merged JSON array of all findings
compound_audit_run_cycle() {
    local agents="$1"
    local diff="$2"
    local plan_summary="$3"
    local prev_findings="$4"
    local cycle="$5"

    local model="${COMPOUND_AUDIT_MODEL:-haiku}"
    local temp_dir
    temp_dir=$(mktemp -d) || return 0

    # Emit cycle start event
    type audit_emit >/dev/null 2>&1 && \
        audit_emit "compound.cycle_start" "cycle=$cycle" "agents=$agents" || true

    # Launch agents in parallel
    local pids=()
    local agent
    for agent in $agents; do
        local prompt
        prompt=$(compound_audit_build_prompt "$agent" "$diff" "$plan_summary" "$prev_findings")

        (
            local output
            output=$(echo "$prompt" | claude -p --model "$model" 2>/dev/null) || output='{"findings":[]}'
            echo "$output" > "$temp_dir/${agent}.json"
        ) &
        pids+=($!)
    done

    # Wait for all agents
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Merge findings from all agents
    local all_findings="[]"
    for agent in $agents; do
        local agent_file="$temp_dir/${agent}.json"
        if [[ -f "$agent_file" ]]; then
            local agent_findings
            agent_findings=$(compound_audit_parse_findings "$(cat "$agent_file")")

            # Emit individual findings as audit events
            local i=0
            local fc
            fc=$(echo "$agent_findings" | jq 'length' 2>/dev/null || echo "0")
            while [[ "$i" -lt "$fc" ]]; do
                local sev desc file line
                sev=$(echo "$agent_findings" | jq -r ".[$i].severity" 2>/dev/null)
                desc=$(echo "$agent_findings" | jq -r ".[$i].description" 2>/dev/null)
                file=$(echo "$agent_findings" | jq -r ".[$i].file" 2>/dev/null)
                line=$(echo "$agent_findings" | jq -r ".[$i].line" 2>/dev/null)
                type audit_emit >/dev/null 2>&1 && \
                    audit_emit "compound.finding" "cycle=$cycle" "agent=$agent" \
                        "severity=$sev" "file=$file" "line=$line" "description=$desc" || true
                i=$((i + 1))
            done

            # Merge into all_findings
            all_findings=$(echo "$all_findings" "$agent_findings" | jq -s '.[0] + .[1]' 2>/dev/null || echo "$all_findings")
        fi
    done

    # Cleanup
    rm -rf "$temp_dir" 2>/dev/null || true

    echo "$all_findings"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash scripts/sw-lib-compound-audit-test.sh`
Expected: All run_cycle tests pass

**Step 5: Commit**

```bash
git add scripts/lib/compound-audit.sh scripts/sw-lib-compound-audit-test.sh
git commit -m "feat: parallel agent execution for compound audit cycles"
```

---

### Task 6: Pipeline Integration — Replace compound_quality Body

**Files:**
- Modify: `scripts/lib/pipeline-intelligence.sh` (~line 1310, inside the cycle loop)
- Modify: `scripts/lib/pipeline-intelligence.sh` (~line 1148, source compound-audit.sh)

**Step 1: Source compound-audit.sh in pipeline-intelligence.sh**

Find the imports section at the top of `pipeline-intelligence.sh` and add:

```bash
# Source compound audit cascade library
if [[ -f "$SCRIPT_DIR/lib/compound-audit.sh" ]]; then
    source "$SCRIPT_DIR/lib/compound-audit.sh"
fi
```

**Step 2: Replace the cycle body (lines ~1310-1365)**

Inside `stage_compound_quality()`, after the hardened quality gates and before the summary, replace the existing cycle loop with the cascade:

```bash
    # ── ADAPTIVE CASCADE AUDIT ──
    local all_findings="[]"
    local active_agents="logic integration completeness"  # Core 3

    # Gather context for agents
    local _cascade_diff
    _cascade_diff=$(git diff "${BASE_BRANCH:-main}...HEAD" 2>/dev/null | head -5000) || _cascade_diff=""
    local _cascade_plan=""
    if [[ -f "$ARTIFACTS_DIR/plan.md" ]]; then
        _cascade_plan=$(head -200 "$ARTIFACTS_DIR/plan.md" 2>/dev/null) || true
    fi

    local cycle=0
    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))

        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Compound Audit — Cycle ${cycle}/${max_cycles} ━━━${RESET}"
        info "Agents: $active_agents"

        # Run agents in parallel
        local cycle_findings
        cycle_findings=$(compound_audit_run_cycle "$active_agents" "$_cascade_diff" "$_cascade_plan" "$all_findings" "$cycle") || cycle_findings="[]"

        # Dedup within this cycle
        cycle_findings=$(compound_audit_dedup_structural "$cycle_findings") || cycle_findings="[]"

        local cycle_count
        cycle_count=$(echo "$cycle_findings" | jq 'length' 2>/dev/null || echo "0")
        local cycle_crit
        cycle_crit=$(echo "$cycle_findings" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")

        # Report findings
        if [[ "$cycle_count" -gt 0 ]]; then
            warn "Cycle ${cycle}: ${cycle_count} findings (${cycle_crit} critical/high)"
            # Count for pipeline scoring
            total_critical=$((total_critical + $(echo "$cycle_findings" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")))
            total_major=$((total_major + $(echo "$cycle_findings" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")))
            total_minor=$((total_minor + $(echo "$cycle_findings" | jq '[.[] | select(.severity == "medium" or .severity == "low")] | length' 2>/dev/null || echo "0")))
        else
            success "Cycle ${cycle}: no findings"
        fi

        # Check convergence
        local converge_reason
        converge_reason=$(compound_audit_converged "$cycle_findings" "$all_findings" "$cycle" "$max_cycles") || converge_reason=""

        # Emit cycle complete event
        type audit_emit >/dev/null 2>&1 && \
            audit_emit "compound.cycle_complete" "cycle=$cycle" "findings=$cycle_count" \
                "critical_high=$cycle_crit" "converged=$converge_reason" || true

        if [[ -n "$converge_reason" ]]; then
            success "Converged: $converge_reason"
            type audit_emit >/dev/null 2>&1 && \
                audit_emit "compound.converged" "reason=$converge_reason" "total_cycles=$cycle" || true
            break
        fi

        # Merge findings for next cycle's context
        all_findings=$(echo "$all_findings" "$cycle_findings" | jq -s '.[0] + .[1]' 2>/dev/null || echo "$all_findings")

        # Escalation: trigger specialists for next cycle
        if type compound_audit_escalate >/dev/null 2>&1; then
            local specialists
            specialists=$(compound_audit_escalate "$cycle_findings") || specialists=""
            if [[ -n "$specialists" ]]; then
                info "Escalating: adding $specialists"
                active_agents="logic integration completeness $specialists"
            fi
        fi
    done

    # Save all findings to artifact
    echo "$all_findings" > "$ARTIFACTS_DIR/compound-audit-findings.json" 2>/dev/null || true
```

**Step 3: Validate syntax**

Run: `bash -n scripts/lib/pipeline-intelligence.sh`
Expected: No errors

**Step 4: Run existing tests to verify no regression**

Run: `bash scripts/sw-lib-compound-audit-test.sh && bash scripts/sw-lib-audit-trail-test.sh`
Expected: Both pass (28/28 audit trail, all compound audit tests)

**Step 5: Commit**

```bash
git add scripts/lib/pipeline-intelligence.sh scripts/lib/compound-audit.sh
git commit -m "feat: integrate compound audit cascade into compound_quality stage"
```

---

### Task 7: Audit Trail Finalize — Include Compound Findings in Reports

**Files:**
- Modify: `scripts/lib/audit-trail.sh` (~line 188, `_audit_build_markdown`)

**Step 1: Add compound findings section to markdown report**

In `_audit_build_markdown()`, after the "Build Loop" section (line ~243), add:

```bash
  # Compound audit findings section
  local compound_events
  compound_events=$(grep '"type":"compound.finding"' "$jsonl_file" 2>/dev/null || true)
  if [[ -n "$compound_events" ]]; then
    cat <<'EOF'

## Compound Audit Findings

EOF
    echo "$compound_events" | while IFS= read -r line; do
      local sev file desc
      sev=$(echo "$line" | grep -o '"severity":"[^"]*' | cut -d'"' -f4)
      file=$(echo "$line" | grep -o '"file":"[^"]*' | cut -d'"' -f4)
      desc=$(echo "$line" | grep -o '"description":"[^"]*' | cut -d'"' -f4)
      echo "- **[$sev]** \`$file\`: $desc"
    done

    # Convergence summary
    local converge_line
    converge_line=$(grep '"type":"compound.converged"' "$jsonl_file" 2>/dev/null | tail -1 || true)
    if [[ -n "$converge_line" ]]; then
      local reason cycles
      reason=$(echo "$converge_line" | grep -o '"reason":"[^"]*' | cut -d'"' -f4)
      cycles=$(echo "$converge_line" | grep -o '"total_cycles":"[^"]*' | cut -d'"' -f4)
      echo ""
      echo "**Converged** after ${cycles} cycle(s): ${reason}"
    fi
  fi
```

**Step 2: Run audit trail tests**

Run: `bash scripts/sw-lib-audit-trail-test.sh`
Expected: 28/28 pass (existing tests unaffected)

**Step 3: Commit**

```bash
git add scripts/lib/audit-trail.sh
git commit -m "feat: include compound audit findings in markdown report"
```

---

## Verification Checklist

1. **Unit tests**: `bash scripts/sw-lib-compound-audit-test.sh` — all tests pass
2. **Audit trail tests**: `bash scripts/sw-lib-audit-trail-test.sh` — 28/28 pass
3. **Loop tests**: `bash scripts/sw-loop-test.sh` — 56/61 (5 pre-existing)
4. **Detection tests**: `bash scripts/sw-lib-pipeline-detection-test.sh` — 70/70
5. **Syntax check**: `bash -n scripts/lib/compound-audit.sh && bash -n scripts/lib/pipeline-intelligence.sh`
6. **E2E**: Run pipeline with compound_quality enabled, verify `compound.cycle_start`, `compound.finding`, and `compound.converged` events in JSONL
