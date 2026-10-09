# Pipeline Audit Trail Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add structured, compliance-grade audit logging so every pipeline run produces full prompt-in → plan-out → test-evidence → audit-verdict → outcome traceability.

**Architecture:** A new `scripts/lib/audit-trail.sh` library provides four functions (`audit_init`, `audit_emit`, `audit_save_prompt`, `audit_finalize`). These are called inline from existing code at key decision points. Events append to a crash-safe JSONL file. At pipeline end, `audit_finalize` reads the JSONL and generates both `pipeline-audit.json` (machine-readable) and `pipeline-audit.md` (human-readable compliance report). All audit calls are wrapped in `|| true` (fail-open — never blocks the pipeline).

**Tech Stack:** Bash, jq, JSONL

---

### Task 1: Create `audit-trail.sh` Library — Tests First

**Files:**
- Create: `scripts/lib/audit-trail.sh`
- Create: `scripts/sw-lib-audit-trail-test.sh`

**Step 1: Write the test file skeleton**

Create `scripts/sw-lib-audit-trail-test.sh`:

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  audit-trail test suite                                                 ║
# ║  Tests audit init, emit, prompt save, and finalize                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: audit-trail Tests"

setup_test_env "sw-lib-audit-trail-test"
trap cleanup_test_env EXIT

# Provide required globals that audit-trail.sh expects
ARTIFACTS_DIR="$TEST_TEMP_DIR/pipeline-artifacts"
LOG_DIR="$TEST_TEMP_DIR/loop-logs"
mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_init creates JSONL and writes pipeline.start event
# ═══════════════════════════════════════════════════════════════════════════════
test_audit_init() {
    # Set up pipeline globals
    ISSUE_NUMBER=42
    GOAL="Add login page"
    PIPELINE_NAME="standard"
    MODEL="sonnet"

    source "$SCRIPT_DIR/lib/audit-trail.sh"
    audit_init

    local jsonl="$ARTIFACTS_DIR/pipeline-audit.jsonl"
    assert_pass "audit_init creates JSONL file" test -f "$jsonl"

    local event_type
    event_type=$(head -1 "$jsonl" | jq -r '.type')
    assert_eq "first event is pipeline.start" "pipeline.start" "$event_type"

    local issue
    issue=$(head -1 "$jsonl" | jq -r '.issue')
    assert_eq "pipeline.start has issue number" "42" "$issue"

    local goal
    goal=$(head -1 "$jsonl" | jq -r '.goal')
    assert_eq "pipeline.start has goal" "Add login page" "$goal"
}
test_audit_init

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_emit appends structured JSON lines
# ═══════════════════════════════════════════════════════════════════════════════
test_audit_emit() {
    # Reset
    ARTIFACTS_DIR="$TEST_TEMP_DIR/emit-test"
    mkdir -p "$ARTIFACTS_DIR"

    source "$SCRIPT_DIR/lib/audit-trail.sh"
    _AUDIT_JSONL="$ARTIFACTS_DIR/pipeline-audit.jsonl"
    : > "$_AUDIT_JSONL"

    audit_emit "stage.start" "stage=build" "config=standard"
    audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=120"

    local line_count
    line_count=$(wc -l < "$_AUDIT_JSONL" | tr -d ' ')
    assert_eq "two events emitted" "2" "$line_count"

    local type1 type2
    type1=$(sed -n '1p' "$_AUDIT_JSONL" | jq -r '.type')
    type2=$(sed -n '2p' "$_AUDIT_JSONL" | jq -r '.type')
    assert_eq "first event type" "stage.start" "$type1"
    assert_eq "second event type" "stage.complete" "$type2"

    local verdict
    verdict=$(sed -n '2p' "$_AUDIT_JSONL" | jq -r '.verdict')
    assert_eq "stage.complete has verdict" "pass" "$verdict"

    # Verify each line is valid JSON
    local valid=true
    while IFS= read -r line; do
        echo "$line" | jq . >/dev/null 2>&1 || valid=false
    done < "$_AUDIT_JSONL"
    assert_pass "all lines are valid JSON" $valid
}
test_audit_emit

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_save_prompt writes prompt file and returns path
# ═══════════════════════════════════════════════════════════════════════════════
test_audit_save_prompt() {
    LOG_DIR="$TEST_TEMP_DIR/prompt-test"
    mkdir -p "$LOG_DIR"

    source "$SCRIPT_DIR/lib/audit-trail.sh"

    local prompt_text="You are a coding agent. Build the login page."
    audit_save_prompt "$prompt_text" 3

    local prompt_file="$LOG_DIR/iteration-3.prompt.txt"
    assert_pass "prompt file created" test -f "$prompt_file"

    local content
    content=$(cat "$prompt_file")
    assert_eq "prompt content matches" "$prompt_text" "$content"
}
test_audit_save_prompt

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_emit with timestamp has ISO-8601 format
# ═══════════════════════════════════════════════════════════════════════════════
test_audit_timestamp_format() {
    ARTIFACTS_DIR="$TEST_TEMP_DIR/ts-test"
    mkdir -p "$ARTIFACTS_DIR"

    source "$SCRIPT_DIR/lib/audit-trail.sh"
    _AUDIT_JSONL="$ARTIFACTS_DIR/pipeline-audit.jsonl"
    : > "$_AUDIT_JSONL"

    audit_emit "test.event" "key=value"

    local ts
    ts=$(head -1 "$_AUDIT_JSONL" | jq -r '.ts')
    # ISO-8601 format: YYYY-MM-DDTHH:MM:SSZ
    assert_pass "timestamp is ISO-8601" echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}
test_audit_timestamp_format

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_finalize generates JSON and Markdown reports
# ═══════════════════════════════════════════════════════════════════════════════
test_audit_finalize() {
    ARTIFACTS_DIR="$TEST_TEMP_DIR/finalize-test"
    LOG_DIR="$TEST_TEMP_DIR/finalize-logs"
    mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR"

    ISSUE_NUMBER=99
    GOAL="Fix bug"
    PIPELINE_NAME="fast"
    MODEL="haiku"
    PIPELINE_START_EPOCH=$(date +%s)

    source "$SCRIPT_DIR/lib/audit-trail.sh"
    _AUDIT_JSONL="$ARTIFACTS_DIR/pipeline-audit.jsonl"

    # Simulate a pipeline run
    audit_emit "pipeline.start" "issue=99" "goal=Fix bug" "template=fast" "model=haiku"
    audit_emit "stage.start" "stage=intake"
    audit_emit "stage.complete" "stage=intake" "verdict=pass" "duration_s=30"
    audit_emit "stage.start" "stage=build"
    audit_emit "loop.prompt" "iteration=1" "chars=15000" "path=iteration-1.prompt.txt"
    audit_emit "loop.response" "iteration=1" "chars=5000" "exit_code=0" "tokens_in=3750" "tokens_out=1250"
    audit_emit "loop.test_gate" "iteration=1" "commands=1" "all_passed=true"
    audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=180"
    audit_emit "pipeline.complete" "outcome=success" "duration_s=210"

    audit_finalize "success"

    # Check JSON report
    local json_report="$ARTIFACTS_DIR/pipeline-audit.json"
    assert_pass "JSON report created" test -f "$json_report"

    local outcome
    outcome=$(jq -r '.outcome' "$json_report")
    assert_eq "JSON has outcome" "success" "$outcome"

    local stage_count
    stage_count=$(jq '.stages | length' "$json_report")
    assert_pass "JSON has stages array" test "$stage_count" -gt 0

    # Check Markdown report
    local md_report="$ARTIFACTS_DIR/pipeline-audit.md"
    assert_pass "Markdown report created" test -f "$md_report"
    assert_pass "Markdown has header" grep -q "Pipeline Audit Report" "$md_report"
    assert_pass "Markdown has stage table" grep -q "intake" "$md_report"
    assert_pass "Markdown has outcome" grep -q "success" "$md_report"
}
test_audit_finalize

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit functions are fail-open (don't crash on bad input)
# ═══════════════════════════════════════════════════════════════════════════════
test_audit_fail_open() {
    ARTIFACTS_DIR="/nonexistent/path"
    LOG_DIR="/nonexistent/path"

    source "$SCRIPT_DIR/lib/audit-trail.sh"

    # These should not crash (fail-open)
    audit_emit "test.event" "key=value" 2>/dev/null || true
    assert_pass "audit_emit survives bad ARTIFACTS_DIR" true

    audit_save_prompt "test prompt" 1 2>/dev/null || true
    assert_pass "audit_save_prompt survives bad LOG_DIR" true
}
test_audit_fail_open

# ═══════════════════════════════════════════════════════════════════════════════
print_test_summary
```

**Step 2: Run the tests to verify they fail**

Run: `bash scripts/sw-lib-audit-trail-test.sh`
Expected: FAIL with "audit-trail.sh: No such file" or "audit_init: command not found"

**Step 3: Write `scripts/lib/audit-trail.sh`**

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  audit-trail.sh — Structured pipeline audit logging                     ║
# ║                                                                         ║
# ║  Provides compliance-grade traceability for pipeline runs:              ║
# ║  prompt in → plan out → test evidence → audit verdict → outcome.       ║
# ║                                                                         ║
# ║  All functions are fail-open (|| true). Audit never blocks pipeline.   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
[[ -n "${_AUDIT_TRAIL_LOADED:-}" ]] && return 0
_AUDIT_TRAIL_LOADED=1

# ─── Internal State ──────────────────────────────────────────────────────────
_AUDIT_JSONL="${ARTIFACTS_DIR:-/tmp}/pipeline-audit.jsonl"

# ─── audit_init ──────────────────────────────────────────────────────────────
# Creates the JSONL file and writes the pipeline.start event.
# Call once at pipeline start (from sw-pipeline.sh).
audit_init() {
    _AUDIT_JSONL="${ARTIFACTS_DIR:-/tmp}/pipeline-audit.jsonl"
    mkdir -p "$(dirname "$_AUDIT_JSONL")" 2>/dev/null || return 0

    local git_sha
    git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    audit_emit "pipeline.start" \
        "issue=${ISSUE_NUMBER:-0}" \
        "goal=${GOAL:-}" \
        "template=${PIPELINE_NAME:-unknown}" \
        "model=${MODEL:-unknown}" \
        "git_sha=$git_sha"
}

# ─── audit_emit ──────────────────────────────────────────────────────────────
# Appends one JSON line to the audit JSONL.
# Usage: audit_emit "event.type" "key1=val1" "key2=val2" ...
audit_emit() {
    local event_type="${1:-unknown}"; shift

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

    # Build JSON object
    local json="{\"ts\":\"$ts\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        # Escape double quotes in values
        val="${val//\"/\\\"}"
        json="${json},\"${key}\":\"${val}\""
        shift
    done
    json="${json}}"

    echo "$json" >> "$_AUDIT_JSONL" 2>/dev/null || true
}

# ─── audit_save_prompt ───────────────────────────────────────────────────────
# Saves the full prompt text to iteration-N.prompt.txt before sending to Claude.
# Usage: audit_save_prompt "$prompt_text" "$iteration_number"
audit_save_prompt() {
    local prompt_text="${1:-}"
    local iteration="${2:-0}"
    local prompt_file="${LOG_DIR:-/tmp}/iteration-${iteration}.prompt.txt"

    mkdir -p "$(dirname "$prompt_file")" 2>/dev/null || return 0
    echo "$prompt_text" > "$prompt_file" 2>/dev/null || true
}

# ─── audit_finalize ──────────────────────────────────────────────────────────
# Reads the JSONL and generates pipeline-audit.json + pipeline-audit.md.
# Call once at pipeline end (success or failure).
# Usage: audit_finalize "success|failure"
audit_finalize() {
    local outcome="${1:-unknown}"
    local json_report="${ARTIFACTS_DIR:-/tmp}/pipeline-audit.json"
    local md_report="${ARTIFACTS_DIR:-/tmp}/pipeline-audit.md"

    [[ ! -f "$_AUDIT_JSONL" ]] && return 0

    # ── Build JSON report ──
    _audit_build_json "$outcome" > "$json_report" 2>/dev/null || true

    # ── Build Markdown report ──
    _audit_build_markdown "$outcome" > "$md_report" 2>/dev/null || true
}

# ─── Internal: JSON report builder ──────────────────────────────────────────
_audit_build_json() {
    local outcome="$1"
    local duration_s=0
    [[ -n "${PIPELINE_START_EPOCH:-}" ]] && duration_s=$(( $(date +%s) - PIPELINE_START_EPOCH ))

    # Extract stages from JSONL
    local stages="[]"
    if command -v jq >/dev/null 2>&1; then
        # Group stage.start + stage.complete pairs
        stages=$(jq -s '
            [.[] | select(.type == "stage.complete")] |
            map({
                name: .stage,
                verdict: .verdict,
                duration_s: (.duration_s // "0" | tonumber)
            })
        ' "$_AUDIT_JSONL" 2>/dev/null || echo "[]")

        # Extract iterations from loop events
        local iterations="[]"
        iterations=$(jq -s '
            [.[] | select(.type == "loop.prompt" or .type == "loop.response" or .type == "loop.test_gate")] |
            group_by(.iteration) |
            map({
                number: (.[0].iteration // "0" | tonumber),
                prompt_chars: ([.[] | select(.type == "loop.prompt") | .chars // "0" | tonumber] | first // 0),
                prompt_path: ([.[] | select(.type == "loop.prompt") | .path // ""] | first // ""),
                response_chars: ([.[] | select(.type == "loop.response") | .chars // "0" | tonumber] | first // 0),
                exit_code: ([.[] | select(.type == "loop.response") | .exit_code // "0" | tonumber] | first // 0),
                tests_passed: ([.[] | select(.type == "loop.test_gate") | .all_passed // ""] | first // "")
            }) | sort_by(.number)
        ' "$_AUDIT_JSONL" 2>/dev/null || echo "[]")

        # Assemble final JSON
        jq -n \
            --arg version "1.0" \
            --arg pipeline_id "pipeline-${ISSUE_NUMBER:-0}" \
            --argjson issue "${ISSUE_NUMBER:-0}" \
            --arg outcome "$outcome" \
            --arg goal "${GOAL:-}" \
            --arg template "${PIPELINE_NAME:-unknown}" \
            --arg model "${MODEL:-unknown}" \
            --argjson duration_s "$duration_s" \
            --argjson stages "$stages" \
            --argjson iterations "$iterations" \
            '{
                version: $version,
                pipeline_id: $pipeline_id,
                issue: $issue,
                outcome: $outcome,
                goal: $goal,
                template: $template,
                model: $model,
                duration_s: $duration_s,
                stages: $stages,
                iterations: $iterations
            }'
    else
        # Fallback without jq
        echo "{\"version\":\"1.0\",\"outcome\":\"$outcome\",\"duration_s\":$duration_s}"
    fi
}

# ─── Internal: Markdown report builder ──────────────────────────────────────
_audit_build_markdown() {
    local outcome="$1"
    local duration_s=0
    [[ -n "${PIPELINE_START_EPOCH:-}" ]] && duration_s=$(( $(date +%s) - PIPELINE_START_EPOCH ))

    # Format duration
    local duration_fmt="${duration_s}s"
    if [[ "$duration_s" -ge 60 ]]; then
        duration_fmt="$(( duration_s / 60 ))m $(( duration_s % 60 ))s"
    fi

    cat <<HEADER
# Pipeline Audit Report — Issue #${ISSUE_NUMBER:-0}

| Field | Value |
|---|---|
| **Pipeline** | ${PIPELINE_NAME:-unknown} |
| **Issue** | #${ISSUE_NUMBER:-0} |
| **Goal** | ${GOAL:-N/A} |
| **Model** | ${MODEL:-unknown} |
| **Duration** | ${duration_fmt} |
| **Outcome** | ${outcome} |

## Stage Summary

| Stage | Duration | Verdict |
|---|---|---|
HEADER

    # Extract stage rows from JSONL
    if command -v jq >/dev/null 2>&1; then
        jq -r 'select(.type == "stage.complete") |
            "| \(.stage) | \(.duration_s // "?")s | \(.verdict // "?") |"' \
            "$_AUDIT_JSONL" 2>/dev/null || true
    fi

    echo ""
    echo "## Build Loop Detail"
    echo ""

    # Extract iteration details
    if command -v jq >/dev/null 2>&1; then
        jq -r 'select(.type == "loop.prompt") |
            "### Iteration \(.iteration)\n- **Prompt**: \(.chars // "?") chars → \(.path // "N/A")\n"' \
            "$_AUDIT_JSONL" 2>/dev/null || true

        jq -r 'select(.type == "loop.response") |
            "- **Response**: \(.chars // "?") chars, exit \(.exit_code // "?")\n"' \
            "$_AUDIT_JSONL" 2>/dev/null || true

        jq -r 'select(.type == "loop.test_gate") |
            "- **Tests**: \(.commands // "?") commands, all passed: \(.all_passed // "?")\n"' \
            "$_AUDIT_JSONL" 2>/dev/null || true
    fi

    echo ""
    echo "---"
    echo "*Generated by Shipwright audit-trail v1.0*"
}
```

**Step 4: Run the tests**

Run: `bash scripts/sw-lib-audit-trail-test.sh`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add scripts/lib/audit-trail.sh scripts/sw-lib-audit-trail-test.sh
git commit -m "feat(audit): add audit-trail.sh library with tests

TDD: emit, save prompt, finalize to JSON + Markdown.
All functions fail-open (|| true)."
```

---

### Task 2: Save Prompts in `loop-iteration.sh`

**Files:**
- Modify: `scripts/lib/loop-iteration.sh:459-470`

**Step 1: Write the test**

Add to `scripts/sw-lib-audit-trail-test.sh` (or verify manually):

The integration test is: after a loop iteration runs, `iteration-N.prompt.txt` exists in LOG_DIR.

For now we verify by reading the code change — the unit tests in Task 1 cover `audit_save_prompt`.

**Step 2: Modify `run_claude_iteration()` in `scripts/lib/loop-iteration.sh`**

Find this block (lines 465-470):

```bash
    final_prompt=$(manage_context_window "$prompt")

    local raw_prompt_chars=${#prompt}
    local prompt_chars=${#final_prompt}
    local approx_tokens=$((prompt_chars / 4))
    info "Prompt: ~${approx_tokens} tokens (${prompt_chars} chars)"
```

Insert after `info "Prompt:..."` (after line 470):

```bash
    # Audit: save full prompt to disk for traceability
    if type audit_save_prompt >/dev/null 2>&1; then
        audit_save_prompt "$final_prompt" "$ITERATION" || true
    fi
    if type audit_emit >/dev/null 2>&1; then
        audit_emit "loop.prompt" "iteration=$ITERATION" "chars=$prompt_chars" \
            "raw_chars=$raw_prompt_chars" "path=iteration-${ITERATION}.prompt.txt" || true
    fi
```

After the Claude response is processed (after line 530, the `accumulate_loop_tokens` call), add:

```bash
    # Audit: record response metadata
    if type audit_emit >/dev/null 2>&1; then
        local response_chars=0
        [[ -f "$log_file" ]] && response_chars=$(wc -c < "$log_file" | tr -d ' ')
        audit_emit "loop.response" "iteration=$ITERATION" "chars=$response_chars" \
            "exit_code=$exit_code" "duration_s=$iter_duration" \
            "path=iteration-${ITERATION}.json" || true
    fi
```

**Step 3: Run the loop tests**

Run: `bash scripts/sw-loop-test.sh`
Expected: 56/61 pass (same as before — 5 pre-existing failures)

**Step 4: Commit**

```bash
git add scripts/lib/loop-iteration.sh
git commit -m "feat(audit): save prompts + emit loop events

Captures iteration-N.prompt.txt before each Claude call.
Emits loop.prompt and loop.response audit events."
```

---

### Task 3: Emit Test Gate and Verification Gap Events in `sw-loop.sh`

**Files:**
- Modify: `scripts/sw-loop.sh:987-992` (after test evidence JSON write)
- Modify: `scripts/sw-loop.sh:2231-2240` (verification gap handler)

**Step 1: Add test gate audit event**

After the existing test evidence write (line 989-990):

```bash
    # Write structured test evidence
    if command -v jq >/dev/null 2>&1; then
        echo "$test_results" > "${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    fi
```

Add:

```bash
    # Audit: emit test gate event
    if type audit_emit >/dev/null 2>&1; then
        local cmd_count=0
        command -v jq >/dev/null 2>&1 && cmd_count=$(echo "$test_results" | jq 'length' 2>/dev/null || echo 0)
        audit_emit "loop.test_gate" "iteration=$ITERATION" "commands=$cmd_count" \
            "all_passed=$all_passed" "evidence_path=test-evidence-iter-${ITERATION}.json" || true
    fi
```

**Step 2: Add verification gap audit events**

In the verification gap handler (after line 2234, the "override_audit" emit_event), add:

```bash
                audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                    "resolution=override" "tests_recheck=pass" || true
```

After line 2238 (the "retry" emit_event), add:

```bash
                audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                    "resolution=retry" "tests_recheck=fail" || true
```

**Step 3: Source `audit-trail.sh` in sw-loop.sh imports**

At line 43 (after the error-actionability source), add:

```bash
# Audit trail for compliance-grade pipeline traceability
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
```

**Step 4: Run the tests**

Run: `bash scripts/sw-loop-test.sh`
Expected: 56/61 pass (unchanged)

Run: `bash scripts/sw-lib-audit-trail-test.sh`
Expected: All pass

**Step 5: Commit**

```bash
git add scripts/sw-loop.sh
git commit -m "feat(audit): emit test gate + verification gap events

Adds audit events in run_test_gate() and verification gap handler.
Sources audit-trail.sh library."
```

---

### Task 4: Add Stage Events and Finalization in `sw-pipeline.sh`

**Files:**
- Modify: `scripts/sw-pipeline.sh:1374-1395` (run_pipeline start)
- Modify: `scripts/sw-pipeline.sh:2500-2565` (pipeline completion)

**Step 1: Source audit-trail.sh and call audit_init**

Near the top of `sw-pipeline.sh` (after existing source statements), add:

```bash
# Audit trail for compliance-grade pipeline traceability
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
```

At the start of `run_pipeline()` (line 1376, after `rotate_event_log_if_needed`), add:

```bash
    # Initialize audit trail for this pipeline run
    if type audit_init >/dev/null 2>&1; then
        audit_init || true
    fi
```

**Step 2: Add stage start/complete events**

In the `run_pipeline()` stage loop, find where each stage runs. There's a section where `stage_*` functions are called (inside the `while IFS= read` loop). Before each stage function call (after the enabled check around line 1433), add:

```bash
        # Audit: stage start
        if type audit_emit >/dev/null 2>&1; then
            audit_emit "stage.start" "stage=$id" || true
        fi
```

After each stage completes (near the "Stage X complete" success message), add:

```bash
        # Audit: stage complete
        if type audit_emit >/dev/null 2>&1; then
            audit_emit "stage.complete" "stage=$id" "verdict=pass" \
                "duration_s=${stage_duration:-0}" || true
        fi
```

For stage failures (near the "Pipeline failed at stage" error message around line 1678), add:

```bash
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=fail" \
                    "duration_s=${stage_duration:-0}" || true
            fi
```

**Step 3: Call audit_finalize at pipeline completion**

At line 2520 (after the success `emit_event "pipeline.completed"`), add:

```bash
        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "success" || true
        fi
```

At line 2565 (after the failure `emit_event "pipeline.completed"`), add:

```bash
        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "failure" || true
        fi
```

**Step 4: Run existing pipeline tests**

Run: `bash scripts/sw-pipeline-test.sh`
Expected: All existing tests pass (audit is fail-open, won't break anything)

**Step 5: Commit**

```bash
git add scripts/sw-pipeline.sh
git commit -m "feat(audit): pipeline-level audit init, stage events, finalize

Calls audit_init at pipeline start, emits stage.start/complete
for each stage, and audit_finalize at pipeline end to generate
pipeline-audit.json + pipeline-audit.md reports."
```

---

### Task 5: Integration Verification

**Files:**
- No new files — verification only

**Step 1: Run all audit tests**

Run: `bash scripts/sw-lib-audit-trail-test.sh`
Expected: All pass

**Step 2: Run loop tests**

Run: `bash scripts/sw-loop-test.sh`
Expected: 56/61 pass (5 pre-existing)

**Step 3: Run detection tests**

Run: `bash scripts/sw-lib-pipeline-detection-test.sh`
Expected: 70/70 pass

**Step 4: Run full npm test suite**

Run: `npm test`
Expected: 191+ tests pass

**Step 5: Run patrol meta-check (bash compat)**

Run: `bash scripts/sw-patrol-meta.sh scripts/lib/audit-trail.sh`
Expected: No `readarray`/`mapfile` violations

**Step 6: Commit version bump**

```bash
# Bump sw-loop.sh VERSION to 3.4.0
sed -i '' 's/VERSION="3.3.0"/VERSION="3.4.0"/' scripts/sw-loop.sh
git add scripts/sw-loop.sh
git commit -m "chore: bump sw-loop version to 3.4.0

Audit trail feature complete:
- pipeline-audit.jsonl (crash-safe event log)
- pipeline-audit.json (machine-readable summary)
- pipeline-audit.md (compliance report)
- iteration-N.prompt.txt (full prompt preservation)"
```

**Step 7: Push**

```bash
git push origin main
```

---

## File Summary

| File | Action | Purpose |
|---|---|---|
| `scripts/lib/audit-trail.sh` | CREATE | Library: audit_init, audit_emit, audit_save_prompt, audit_finalize |
| `scripts/sw-lib-audit-trail-test.sh` | CREATE | Tests for all audit functions |
| `scripts/lib/loop-iteration.sh` | MODIFY | Save prompts, emit loop.prompt/loop.response events |
| `scripts/sw-loop.sh` | MODIFY | Source library, emit test_gate/verification_gap events |
| `scripts/sw-pipeline.sh` | MODIFY | Source library, audit_init, stage events, audit_finalize |

## Verification Checklist

- [ ] `bash scripts/sw-lib-audit-trail-test.sh` — all pass
- [ ] `bash scripts/sw-loop-test.sh` — 56/61 (5 pre-existing)
- [ ] `bash scripts/sw-lib-pipeline-detection-test.sh` — 70/70
- [ ] `npm test` — 191+ pass
- [ ] `bash scripts/sw-patrol-meta.sh scripts/lib/audit-trail.sh` — no bash compat violations
- [ ] Run real pipeline — verify `pipeline-audit.jsonl`, `.json`, `.md` generated
