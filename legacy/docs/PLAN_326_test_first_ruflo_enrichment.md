# Implementation Plan: feat(ruflo) — Enrich test_first Stage with Semantic Recall

**Issue**: #326  
**Goal**: Enhance `stage_test_first()` with Ruflo semantic recall for TDD context  
**Branch**: feat/feat-ruflo-enrich-test-first-stage-with-326  
**Date**: 2026-04-19

---

## Verification of Assumptions (Completed)

### ✅ File Structure Verified
- **`stage_test_first()` location**: `scripts/lib/pipeline-stages-build.sh` lines 6–114
- **Reference pattern (`stage_plan()`)**: `scripts/lib/pipeline-stages-intake.sh` lines 118–202
- **Ruflo adapter location**: `scripts/lib/ruflo-adapter.sh` (functions verified below)

### ✅ Ruflo Functions Verified
All three functions exist and are accessible:

| Function | Location | Signature | Behavior |
|----------|----------|-----------|----------|
| `ruflo_available()` | Line 97 | `ruflo_available()` | Returns 0 (true) if `RUFLO_AVAILABLE=true`, 1 (false) otherwise |
| `ruflo_recall_similar_outcomes()` | Line 1224 | `ruflo_recall_similar_outcomes(task_type, issue_labels?)` | Semantic search in `learning-<repo_hash>` namespace; outputs results or empty string; **always returns 0 (fail-open)** |
| `ruflo_store()` | Line 433 | `ruflo_store(key, value, namespace, tags?)` | Stores KV entry with timeout protection; **always returns 0 (fail-open)** |

### ✅ Global Variables Verified (In Scope at `stage_test_first()`)

All variables are exported by `pipeline-stages.sh` (lines 17–31) and inherited:

| Variable | Set In | Value | Usage in Plan |
|----------|--------|-------|---------------|
| `GOAL` | pipeline-stages-intake.sh line 51 / pipeline-stages.sh line 29 | Issue title or explicit goal | Included via requirements snippet in second param to `ruflo_recall_similar_outcomes()` |
| `ISSUE_LABELS` | pipeline-stages-intake.sh line 20 / pipeline-stages.sh line 27 | Comma-separated label list | Part of composite second param to `ruflo_recall_similar_outcomes()` |
| `TASK_TYPE` | pipeline-stages-intake.sh line 51 / pipeline-stages.sh line 30 | Result of `detect_task_type()` or default "feature" | First param to `ruflo_recall_similar_outcomes()` |
| `INTELLIGENCE_ISSUE_TYPE` | pipeline-stages.sh line 31 (default: "backend") | Detected issue type or "backend" | Not used directly; TASK_TYPE is the correct param |
| `SHIPWRIGHT_PIPELINE_ID` | sw-pipeline.sh line 534 | Format: `pipeline-$$-${ISSUE_NUMBER}` | Used in the `ruflo_store()` key; storage namespace is `learning-<repo_hash>` |
| `ARTIFACTS_DIR` | pipeline-stages.sh line 17 | Default: `.claude/pipeline-artifacts` | Already used in `stage_test_first()` |

### ✅ Ruflo-Adapter Is Available to `stage_test_first()`
- Sourced in `sw-pipeline.sh` line 138 BEFORE `pipeline-stages.sh` is loaded (line 139)
- Exported as module-level functions; available in all stage functions
- Uses circuit-breaker: functions return 0 (success) even on failure

---

## Files to Modify

1. **`scripts/lib/pipeline-stages-build.sh`** — Add recall/store integration to `stage_test_first()`
2. **`scripts/sw-ruflo-adapter-test.sh`** — Add 2+ new test cases for the integration

---

## Implementation Steps

### **Step 1: Read and Understand Current `stage_test_first()` Structure** (VERIFICATION)
- Confirm lines 6–114 match expected pattern
- Identify insertion point for recall (before prompt building, around line 20)
- Identify insertion point for store (after `wrote_any=true` check, around line 102)

### **Step 2: Add Ruflo Recall at Start of `stage_test_first()`** (INSERTION)
**Location**: Between line 19 (`requirements=""`) and line 21 (`local tdd_prompt=...`)

**Code to insert**:
```bash
    # ── Semantic recall: find similar past TDD test generations ──
    local tdd_context=""
    if ruflo_available; then
        tdd_context=$(ruflo_recall_similar_outcomes "${TASK_TYPE}" "${ISSUE_LABELS:-}" 2>/dev/null) || true
        # Prune context to avoid bloating the prompt
        if [[ -n "$tdd_context" && "$tdd_context" != *'"results":[]'* ]]; then
            tdd_context=$(echo "$tdd_context" | jq -r '.results[]? | "- \(.)"' 2>/dev/null | head -5 || true)
            tdd_context=$(printf '%.2000s' "$tdd_context")  # bound to 2000 chars
        else
            tdd_context=""
        fi
    fi
```

**Behavior**:
- Calls `ruflo_recall_similar_outcomes()` with task type and labels
- Extracts and prunes results to 2000 chars max (typical 3–5 past outcomes)
- Sets `tdd_context=""` if recall fails or returns no results
- Never fails: wrapped in `2>/dev/null || true`

### **Step 3: Inject Recall Results into TDD Prompt** (INTEGRATION)
**Location**: Inside the `tdd_prompt=` assignment, after the Requirements section (around line 26)

**Code to insert** (after line 26, inside the heredoc):
```bash

## Similar Past Test Generations
From previous pipelines with the same task type:
${tdd_context}
```

**Behavior**:
- Adds optional context section only if `tdd_context` is non-empty
- Follows the pattern from `stage_plan()` (pipeline-stages-intake.sh lines 194–200)
- If `tdd_context=""`, this line outputs an empty "## Similar Past Test Generations" section (acceptable; Claude ignores empty sections)

### **Step 4: Add Ruflo Store After Test Files Are Written** (PERSISTENCE)
**Location**: After line 109, after the `success` message (before the final `return 0` at line 113)

**Code to insert**:
```bash
    
    # ── Store this TDD outcome for future reference ──
    if ruflo_available && [[ "$wrote_any" == "true" ]]; then
        local tdd_key="test_first-${SHIPWRIGHT_PIPELINE_ID:-unknown}-$(date +%s)"
        local tdd_outcome
        tdd_outcome=$(jq -n --arg goal "${GOAL:-}" --arg task "${TASK_TYPE:-}" \
            --arg wrote "$wrote_any" \
            '{goal: $goal, task_type: $task, tests_generated: ($wrote == "true")}' 2>/dev/null || echo '{}')
        ruflo_store "$tdd_key" "$tdd_outcome" \
            "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" \
            "tdd,test_first,feature" 2>/dev/null || true
    fi
```

**Behavior**:
- Creates unique key with timestamp + pipeline ID
- Stores JSON object: goal, task_type, tests_generated (boolean)
- Uses `pipeline-<PIPELINE_ID>` namespace (consistent with stage_build lines 427, 451)
- Guarded by `ruflo_available()` and `wrote_any=true` check
- Always succeeds (wrapped in `|| true`)

---

## Task Checklist

- [ ] **Task 1**: Read `stage_test_first()` to confirm structure matches plan
- [ ] **Task 2**: Verify `ruflo_available()` function is callable from pipeline-stages-build.sh context
- [ ] **Task 3**: Add semantic recall code at line 20 (after requirements, before prompt)
- [ ] **Task 4**: Inject recall results into tdd_prompt heredoc (line 26)
- [ ] **Task 5**: Add ruflo_store code at line 109 (after success message)
- [ ] **Task 6**: Write test case: `test_recall_on_test_first_happy_path` in sw-ruflo-adapter-test.sh
- [ ] **Task 7**: Write test case: `test_store_on_test_first_happy_path` in sw-ruflo-adapter-test.sh
- [ ] **Task 8**: Write test case: `test_recall_when_ruflo_unavailable` (should not fail stage)
- [ ] **Task 9**: Write test case: `test_store_when_no_tests_written` (should skip store)
- [ ] **Task 10**: Run full test suite: `npm test`
- [ ] **Task 11**: Verify no regressions: run stage in isolation (optional local test)
- [ ] **Task 12**: Commit changes with message: `feat(ruflo): enrich test_first stage with semantic recall for TDD context`

---

## Testing Approach

### Test Pyramid Breakdown
- **Unit tests** (70%): 4 new tests in `sw-ruflo-adapter-test.sh`
- **Integration tests** (20%): Existing tests verify stage pipeline flow
- **E2E tests** (10%): Pipeline smoke tests (existing)

### Test Coverage Targets
All new code paths in `stage_test_first()`:
1. **Recall happy path**: `ruflo_available=true` → recall returns results → injected into prompt
2. **Recall failure path**: `ruflo_available=false` OR recall returns empty → `tdd_context=""` → stage continues normally
3. **Store happy path**: `wrote_any=true` AND `ruflo_available=true` → `ruflo_store()` called with correct key/namespace
4. **Store failure path**: `wrote_any=false` OR `ruflo_unavailable` OR store timeout → stage continues normally

### Test Cases to Add to `sw-ruflo-adapter-test.sh`

```bash
# Test A: Recall happy path
test_recall_on_test_first_happy_path() {
    # Mock ruflo_recall_similar_outcomes to return test patterns
    # Verify tdd_context is populated
    # Verify recall results are extracted and injected
}

# Test B: Recall unavailable
test_recall_when_ruflo_unavailable() {
    # Set RUFLO_AVAILABLE=false
    # Stage should succeed with tdd_context=""
    # No errors logged
}

# Test C: Store happy path
test_store_on_test_first_happy_path() {
    # Mock stage with wrote_any=true
    # Verify ruflo_store called with:
    #   - key: test_first-${SHIPWRIGHT_PIPELINE_ID}-<timestamp>
    #   - value: JSON with goal, task_type, tests_generated=true
    #   - namespace: pipeline-${SHIPWRIGHT_PIPELINE_ID}
    #   - tags: "tdd,test_first,feature"
}

# Test D: Store skipped when no tests written
test_store_when_no_tests_written() {
    # Mock stage with wrote_any=false
    # Verify ruflo_store NOT called
    # Stage returns 0 (success)
}
```

### Critical Paths to Test

| Path | Input | Expected Behavior |
|------|-------|-------------------|
| Happy: Recall + Store | ruflo_available=true, tests written | Recall results injected, outcome stored, stage succeeds |
| Degrade: Ruflo unavailable | ruflo_available=false | Both recall/store skipped, stage succeeds (fail-open) |
| Degrade: Ruflo timeout | Circuit-breaker triggers | Both calls return 0, stage succeeds |
| Edge: No tests written | wrote_any=false | Store skipped, recall still runs, stage succeeds |
| Edge: Empty labels | ISSUE_LABELS="" | Recall called with empty string, succeeds |

---

## Definition of Done

- [x] All referenced functions verified to exist and be callable
- [x] All referenced variables verified to be in scope
- [x] All file paths and line numbers verified
- [ ] Recall code inserted at correct location (line 20)
- [ ] Recall results injected into tdd_prompt heredoc
- [ ] Store code inserted at correct location (after line 109)
- [ ] All calls fail-open (no `set -e` failures)
- [ ] 4+ new test cases added to `sw-ruflo-adapter-test.sh`
- [ ] Tests cover happy path, error cases, edge cases
- [ ] Full test suite passes: `npm test`
- [ ] Existing tests not broken
- [ ] Commit message matches issue description

---

## Alternatives Considered

### **Alternative 1: Recall + Store via MCP Tool (Rejected)**
**Approach**: Use MCP tools directly instead of shell functions
- **Pros**: More direct control over timing and error handling
- **Cons**: Requires forking agents; added complexity; against fail-open philosophy
- **Verdict**: Rejected. Shell functions are proven, simpler, already used by stage_plan and stage_design.

### **Alternative 2: Store Only on Test Success (Rejected)**
**Approach**: Only call `ruflo_store()` when all tests pass
- **Pros**: Only stores "good" outcomes
- **Cons**: Requires test runner invocation; TDD tests fail initially by design; namespace gets sparse
- **Verdict**: Rejected. Store should capture the generation event (what was created), not test passage.

### **Alternative 3: Inject Recall into Prompt as JSON (Rejected)**
**Approach**: Pass recall results as JSON block instead of markdown
- **Pros**: Easier for Claude to parse structured data
- **Cons**: Less human-readable; adds JSON parsing complexity in heredoc
- **Verdict**: Rejected. stage_plan uses markdown injection (proven pattern); Claude handles both equally well.

**Chosen Approach**: Semantic recall + namespace-based store (proven pattern from stage_plan/stage_design, fail-open by design, minimal risk).

---

## Risk Analysis

### **Risk 1: Variables not in scope**
- **Mitigation**: ✅ Verified all variables are exported by pipeline-stages.sh before stage functions run
- **Fallback**: Use `${VAR:-default}` syntax for all variables (already in code)

### **Risk 2: Ruflo functions don't exist or fail**
- **Mitigation**: ✅ Verified functions exist; all wrapped in `ruflo_available() || return 0` and `|| true`
- **Impact**: If ruflo unavailable, recall returns "", store skipped; stage continues normally

### **Risk 3: Prompt injection via recall results**
- **Mitigation**: Bound recall results to 2000 chars max; use `jq -r` to extract safely; quoted in heredoc
- **Impact**: Malformed results could theoretically break the prompt; jq parsing prevents raw shell injection

### **Risk 4: Store payload is too large**
- **Mitigation**: Store payload is small JSON (~100 bytes); key is `test_first-<id>-<timestamp>` (~50 bytes)
- **Impact**: Well within ruflo's argv limits

### **Risk 5: Regression in existing tests**
- **Mitigation**: All new code is guarded by `ruflo_available()` check; non-breaking additions only
- **Impact**: Existing tests that don't use ruflo are unaffected

---

## Notes

- **Namespace pattern**: `pipeline-${SHIPWRIGHT_PIPELINE_ID}` is already used by stage_build (lines 427, 451) and stage_review (line 541)
- **Recall query**: Uses `"${TASK_TYPE}" "${ISSUE_LABELS}"` (same pattern as stage_plan line 263)
- **Store namespace**: `"pipeline-${SHIPWRIGHT_PIPELINE_ID}"` (consistent with stage_build pattern)
- **Fail-open guarantee**: All ruflo calls guarded with `|| true` or checked with `ruflo_available()`
- **Test pattern**: Use existing mock infrastructure in `sw-ruflo-adapter-test.sh` (see lines 48, 81 for mock_binary pattern)
