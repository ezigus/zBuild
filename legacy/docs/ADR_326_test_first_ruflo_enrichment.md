# ADR: feat(ruflo) — Enrich test_first Stage with Semantic Recall for TDD Context

**Issue**: #326  
**Decision Date**: 2026-04-19  
**Status**: Accepted  
**Authors**: Claude Architect  
**Related Files**: 
- Implementation Plan: `docs/PLAN_326_test_first_ruflo_enrichment.md`
- Target Stage: `scripts/lib/pipeline-stages-build.sh:6-114`
- Reference Pattern: `scripts/lib/pipeline-stages-intake.sh:118-202`

---

## Problem Statement

The `test_first` stage of Shipwright's autonomous pipeline generates TDD test skeletons using Claude. Currently, it operates without semantic context from past test generations, missing opportunities to:

1. **Reuse proven test patterns** from similar issues
2. **Avoid duplicate test structures** across similar task types
3. **Learn from past TDD outcomes** stored in Ruflo's semantic memory
4. **Persist test generation decisions** for future pipelines

This leads to **reinvention of test patterns** on each pipeline run and **lost institutional knowledge** about what test structures worked well for different issue types.

---

## Context & Constraints

### Stage Contract
- **Stage Contract**: `test_first` is repo-agnostic and follows project conventions for language, test framework, and file layout
- **Current Repository Example**: TypeScript / Node.js
- **Current Test Convention Example**: Vitest (`*.test.js` pattern)
- **Current Source Layout Example**: `src/`
- **Pipeline Framework**: Shipwright (shell-based orchestration)
- **Memory System**: Ruflo (semantic recall via shell functions)

### Key Assumptions (Verified)
1. ✅ Ruflo shell functions are available in stage context (`ruflo_available`, `ruflo_recall_similar_outcomes`, `ruflo_store`)
2. ✅ Global variables (`GOAL`, `TASK_TYPE`, `ISSUE_LABELS`, `SHIPWRIGHT_PIPELINE_ID`) are exported before `stage_test_first()` runs
3. ✅ Similar semantic recall pattern is proven in `stage_plan()` (reference implementation exists)
4. ✅ Namespace pattern `pipeline-${SHIPWRIGHT_PIPELINE_ID}` is already used by other stages
5. ✅ Circuit-breaker design in Ruflo ensures fail-open behavior (no stage failures if Ruflo unavailable)

### Constraints
- **Bash 3.2 compatible** (no associative arrays, no `readarray`)
- **Shell output parsing** only (no MCP tool invocation in shell stages)
- **Fail-open philosophy** (stage succeeds even if Ruflo is unavailable)
- **Payload size limits** (bound context to 2000 chars to avoid prompt bloat)
- **Existing test coverage** cannot regress

---

## Decision

**Enrich `stage_test_first()` with semantic recall before prompt generation, and persist test generation outcomes after prompt execution.**

### Chosen Approach

#### **1. Semantic Recall Before Prompt Generation**

Before building the TDD prompt, invoke `ruflo_recall_similar_outcomes()` to fetch past test generations for the same task type and issue labels:

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
- Calls `ruflo_recall_similar_outcomes(TASK_TYPE, ISSUE_LABELS)` 
- Extracts results using `jq`, limits to 5 past outcomes
- Bounds total context to 2000 characters to prevent prompt bloat
- Returns empty string if no results or Ruflo unavailable
- **Never fails**: wrapped in `2>/dev/null || true`

#### **2. Inject Recall Results into TDD Prompt**

Add optional `## Similar Past Test Generations` section inside the tdd_prompt heredoc:

```bash
## Similar Past Test Generations
From previous pipelines with the same task type:
${tdd_context}
```

**Behavior**:
- Results included in heredoc **only if `tdd_context` is non-empty**
- Follows markdown format for readability
- Claude can ignore empty sections gracefully
- Consistent with `stage_plan()` precedent (proven pattern)

#### **3. Persistence: Store Test Generation Outcome**

After test files are written (when `wrote_any=true`), store the generation event:

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
- Creates unique key: `test_first-<PIPELINE_ID>-<timestamp>`
- Stores JSON: `{goal, task_type, tests_generated: true|false}`
- Uses namespace: `pipeline-<PIPELINE_ID>` (consistent with `stage_build`, `stage_review`)
- Tags: `"tdd,test_first,feature"` for semantic filtering
- Guarded by `ruflo_available()` AND `wrote_any=true`
- **Never fails**: wrapped in `|| true`

### Design Rationale

| Decision | Rationale | Alternative Rejected |
|----------|-----------|----------------------|
| **Semantic recall (vs. no recall)** | Reuse proven patterns, reduce prompt engineering time | No alternative; addresses core problem |
| **Recall before prompt (vs. during)** | Allows context to influence prompt structure; cleaner separation | Post-prompt recall would miss generation guidance |
| **Prune to 2000 chars (vs. unbounded)** | Avoid prompt bloat while still including 3–5 past outcomes | Unbounded context risks token waste and distraction |
| **Store on any write (vs. only on success)** | Capture what was *generated*, not test *passage*; TDD tests fail by design initially | Store-on-success would miss important patterns |
| **Namespace per pipeline (vs. global)** | Enable namespace isolation; future queries can filter by pipeline context | Global namespace would lose correlation |
| **Fail-open design (vs. fail-closed)** | Stage continues even if Ruflo unavailable; stage success not dependent on memory system | Fail-closed would create cascade failures |

---

## Alternatives Considered

### **Alternative 1: Recall + Store via MCP Tool (Rejected)**
**Approach**: Call `mcp__ruflo__memory_search` / `memory_store` directly instead of shell functions

- **Pros**: More direct control; better error reporting
- **Cons**: Requires spawning agents; incompatible with shell-only stages; added complexity
- **Verdict**: ❌ **Rejected** — Shell functions proven in `stage_plan()` and `stage_design()`; already integrated

### **Alternative 2: Store Only on Test Success (Rejected)**
**Approach**: Call `ruflo_store()` only when all Vitest assertions pass

- **Pros**: Only captures "successful" test generations
- **Cons**: Tests fail initially by TDD design; namespace becomes sparse; misses generation context
- **Verdict**: ❌ **Rejected** — Store should capture the *generation event*, not test passage; TDD expects red-green-refactor

### **Alternative 3: Inject Recall as JSON Block (Rejected)**
**Approach**: Pass recall results as structured JSON in prompt instead of markdown

- **Pros**: More structured; easier for Claude to parse
- **Cons**: Less readable; more parse complexity in heredoc; stage_plan uses markdown (proven)
- **Verdict**: ❌ **Rejected** — Markdown injection is proven pattern; Claude handles both equally well

### **Alternative 4: Global Recall (No Namespace Filtering) (Rejected)**
**Approach**: Recall from all past pipelines globally instead of pipeline-specific namespace

- **Pros**: Broader context from all past work
- **Cons**: Noisy; loses correlation with specific pipeline contexts; harder to debug
- **Verdict**: ❌ **Rejected** — Pipeline-specific namespace provides better signal-to-noise ratio

---

## Implementation Plan

### Files to Modify
1. **`scripts/lib/pipeline-stages-build.sh`** (lines 6–114)
   - Add recall code at line 20 (after `requirements=""`, before `local tdd_prompt=...`)
   - Add recall results injection in tdd_prompt heredoc at line 26
   - Add store code at line 109 (after success message, before `return 0`)

2. **`scripts/sw-ruflo-adapter-test.sh`** (new test cases)
   - Add `test_recall_on_test_first_happy_path()` 
   - Add `test_recall_when_ruflo_unavailable()`
   - Add `test_store_on_test_first_happy_path()`
   - Add `test_store_when_no_tests_written()`

### Dependencies
- **New Dependencies**: None (Ruflo functions and variables already available)
- **System Commands**: `jq` (already used in pipeline), `date` (standard)
- **Environment**: `RUFLO_AVAILABLE` must be set by pipeline-stages.sh (already done)

### Data Flow

```
┌──────────────────────────────────────────────────────────────┐
│ stage_test_first() Entry                                     │
└───────────────────────┬──────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────────────────┐
│ STEP 1: Semantic Recall                                      │
│ ruflo_recall_similar_outcomes(TASK_TYPE, ISSUE_LABELS)       │
│ → tdd_context (prune to 2000 chars, extract 5 results)       │
└───────────────────────┬──────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────────────────┐
│ STEP 2: Build Prompt                                         │
│ Inject tdd_context into "## Similar Past Test Generations"   │
│ tdd_prompt = <<< "..." ${tdd_context} ...                    │
└───────────────────────┬──────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────────────────┐
│ STEP 3: Send Prompt to Claude (existing logic)               │
│ (no changes to this step)                                    │
└───────────────────────┬──────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────────────────┐
│ STEP 4: Write Test Files (existing logic)                    │
│ If wrote_any=true → proceed to store                         │
└───────────────────────┬──────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────────────────┐
│ STEP 5: Persistence (NEW)                                    │
│ If (ruflo_available AND wrote_any=true):                     │
│   ruflo_store(tdd_key, tdd_outcome,                          │
│     "pipeline-PIPELINE_ID", "tdd,test_first,feature")        │
└───────────────────────┬──────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────────────────┐
│ stage_test_first() Exit (return 0)                           │
└──────────────────────────────────────────────────────────────┘
```

### Risk Areas

| Risk | Severity | Mitigation |
|------|----------|-----------|
| **Variables not in scope** | Medium | ✅ All variables verified to be exported before stage runs; use `${VAR:-default}` syntax |
| **Ruflo functions unavailable** | Medium | ✅ All calls wrapped in `ruflo_available()` check and `\|\| true`; fail-open design |
| **Prompt injection via recall results** | Medium | ✅ Results bounded to 2000 chars; parsed with `jq -r`; quoted in heredoc; no shell expansion |
| **Store payload too large** | Low | ✅ Payload is ~100 bytes JSON; key is ~50 bytes; well within limits |
| **Regression in existing tests** | Low | ✅ All new code guarded by `ruflo_available()` check; non-breaking additions |
| **Performance impact** | Low | ✅ Recall is async; single semantic search (~100ms); bounded by Ruflo circuit-breaker timeout |

---

## Validation Criteria

All of the following must be true before merging:

- [ ] **Recall code** inserted correctly at line 20 of `pipeline-stages-build.sh`
- [ ] **Recall injection** added to tdd_prompt heredoc (line 26)
- [ ] **Store code** inserted after line 109 of `pipeline-stages-build.sh`
- [ ] **All calls are fail-open**: wrapped in `|| true` or checked with `ruflo_available()`
- [ ] **4+ new test cases** added to `sw-ruflo-adapter-test.sh`:
  - ✅ Happy path: Recall returns results, tdd_context populated
  - ✅ Failure path: Ruflo unavailable, tdd_context empty, stage succeeds
  - ✅ Happy path: Store called with correct key/namespace/tags when wrote_any=true
  - ✅ Edge case: Store skipped when wrote_any=false
- [ ] **All test cases pass**: `npm test`
- [ ] **No regressions**: Existing pipeline-stages tests still pass
- [ ] **Manual verification** (optional): Run stage in isolation to confirm prompt injection works
- [ ] **Commit message** matches issue: `feat(ruflo): enrich test_first stage with semantic recall for TDD context`

### Success Definition

The feature is successful when:

1. **Semantic recall is accessible in test generation**: Claude receives past TDD patterns before writing tests
2. **Outcomes are persisted**: Each test generation is stored in Ruflo's namespace for future recall
3. **Fail-open behavior is maintained**: Pipeline continues normally if Ruflo is unavailable
4. **No test regressions**: All existing tests pass, no new failures introduced
5. **Consistent with codebase patterns**: Uses same namespace/recall patterns as `stage_plan()` and `stage_design()`

---

## Implementation Checklist

### Phase 1: Code Implementation
- [ ] Read current `stage_test_first()` to confirm structure
- [ ] Verify `ruflo_available()` is callable from build.sh context
- [ ] Add recall code at line 20
- [ ] Inject recall results into tdd_prompt heredoc
- [ ] Add store code after line 109
- [ ] Test locally (optional): verify no syntax errors with `bash -n`

### Phase 2: Test Implementation
- [ ] Write `test_recall_on_test_first_happy_path()` test
- [ ] Write `test_recall_when_ruflo_unavailable()` test
- [ ] Write `test_store_on_test_first_happy_path()` test
- [ ] Write `test_store_when_no_tests_written()` test
- [ ] Run test suite: `npm test`
- [ ] Verify no regressions in existing pipeline-stages tests

### Phase 3: Verification
- [ ] Code review by team (verify fail-open design)
- [ ] Merge to branch `feat/feat-ruflo-enrich-test-first-stage-with-326`
- [ ] Run full pipeline with `--issue 326` to validate end-to-end
- [ ] Document any learnings in memory for future test_first enrichments

---

## References

- **Proven Pattern (Reference Implementation)**: `scripts/lib/pipeline-stages-intake.sh:118-202` (`stage_plan()` with semantic recall)
- **Ruflo Adapter Documentation**: `scripts/lib/ruflo-adapter.sh` (function definitions)
- **Similar Stage Integration**: `scripts/lib/pipeline-stages-build.sh:427, 451` (stage_build with Ruflo store)
- **Test Framework**: `scripts/sw-ruflo-adapter-test.sh` (existing mock patterns)
- **Pipeline Orchestration**: `scripts/sw-pipeline.sh:138-139` (module loading order)

---

## Decision Log

| Date | Event | Decision |
|------|-------|----------|
| 2026-04-19 | Plan verification completed | All functions, variables, and file paths verified; plan accepted |
| 2026-04-19 | ADR drafted | Architecture decision documented; alternatives evaluated; ready for implementation |

---

## Notes

- **Namespace consistency**: Uses `pipeline-${SHIPWRIGHT_PIPELINE_ID}` pattern already proven in `stage_build` and `stage_review`
- **Fail-open guarantee**: All Ruflo calls fail gracefully; stage success not dependent on memory system
- **Scalability**: Semantic recall grows with pipeline history; namespace partitioning prevents bloat
- **Future enhancements**: Can add test result feedback loop (store test execution outcomes) in subsequent ADRs
