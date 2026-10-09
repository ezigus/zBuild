# Implementation Plan: feat(ruflo): [03.1] Self-Heal Hypothesis Hive

**Status: PLAN — Ready for Design Review**  
**Created: 2026-05-04T21:25:00Z**  
**Phase: Plan (Stage 1 of 12)**

---

## Executive Summary

The self-heal hypothesis hive feature is **80% complete**. Core implementation is done and tested; remaining work is completing the full test suite (unit, integration, performance) and validating under real conditions.

### What's Done ✅
- `ruflo_execute_self_heal_hive()` function fully implemented (lines 1811–2004 in `scripts/lib/ruflo-adapter.sh`)
- Four environmental gates (env flag, ruflo availability, hive initialization, hive_id validation)
- Input bounding for error text (8000 bytes) and changed files (2000 bytes)
- Namespace seeding with failure context and historical recall
- Specialist spawning (3 agents, 12s timeout, non-fatal on failure)
- Triage orchestration with unified goal for 3 specialists (20s timeout)
- Hypothesis union reading (5s timeout)
- Synthesis phase with argmin(cost) + argmax(confidence) logic (8s timeout)
- Fallback path when synthesis fails (emit union as best-effort)
- Proper event emission and logging
- Integration into `sw-loop.sh` line 2703–2717 with GOAL injection
- Security review and static analysis fixes (commit 136433d)
- Existing test coverage: 25+ tests in `sw-ruflo-adapter-test.sh` lines 4244–4500+

### What Remains ❌
1. **Complete unit test suite** — Test all branches and error paths
2. **Integration tests** — Full workflow with mocked ruflo
3. **Performance profiling** — Verify < 60s overhead and zero overhead when disabled
4. **Full `npm test` validation** — Ensure no regressions across all suites

---

## Architecture & Design

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      sw-loop.sh                             │
│                  (TEST_PASSED=false)                        │
└────────────────────┬────────────────────────────────────────┘
                     │ calls (lines 2703-2717)
                     ↓
┌─────────────────────────────────────────────────────────────┐
│            ruflo_execute_self_heal_hive()                   │
│                                                              │
│  Gate Layer (early-exit, fail-open)                        │
│  ├─ RUFLO_SELF_HEAL_HIVE=true?                             │
│  ├─ ruflo binary available?                                │
│  ├─ RUFLO_HIVE_AVAILABLE=true?                             │
│  └─ RUFLO_HIVE_ID non-empty?                               │
│                                                              │
│  Specialist Hive (async, 12s spawn + 20s triage)           │
│  ├─ Namespace: hive-self-heal-${PIPELINE_ID}               │
│  ├─ Store: error context, changed files, history           │
│  ├─ Spawn: 3 specialists                                    │
│  │  └─ Roles: mock-boundary, async-timing, schema-type    │
│  └─ Triage: orchestrate across specialists                  │
│                                                              │
│  Synthesis (8s + fallback)                                 │
│  ├─ Read specialist hypotheses from namespace              │
│  ├─ Select: argmin(cost), tiebreak argmax(confidence)      │
│  └─ Fallback: emit union if synthesis fails                │
│                                                              │
│  Output: printf '%s\n' "$_selected"  (hypothesis text)     │
│  Events: ruflo.self_heal_hive_* (emit_event)               │
└─────────────────────────────────────────────────────────────┘
                     │ returns hypothesis text
                     ↓
┌─────────────────────────────────────────────────────────────┐
│              sw-loop.sh (lines 2707-2717)                   │
│                                                              │
│  Inject hypothesis into GOAL with header:                  │
│  "## Self-Heal Hypothesis (hive-selected)"                 │
│                                                              │
│  Sanitize sentinels (<<<, >>>)                            │
│                                                              │
│  Next Claude iteration sees GOAL + hypothesis              │
└─────────────────────────────────────────────────────────────┘
```

### Interface Contracts

**Function Signature**
```bash
ruflo_execute_self_heal_hive(error_text: string, changed_files: string) -> string
```

**Inputs**
- `error_text`: Full test failure output (unbounded, will be trimmed to 8000 bytes)
- `changed_files`: Comma-separated file list (unbounded, will be trimmed to 2000 bytes)

**Output**
- Returns selected hypothesis text to stdout (< 500 chars), empty string if skipped/failed
- **Exit Code**: Always 0 (fail-open, non-fatal)

**Error Contracts**
- RUFLO_SELF_HEAL_HIVE not "true" → silent no-op (return 0, empty stdout)
- ruflo unavailable → silent no-op (event logged, return 0)
- RUFLO_HIVE_AVAILABLE not "true" → silent no-op (event logged, return 0)
- RUFLO_HIVE_ID empty → silent no-op with warning (event logged, return 0)
- Spawn timeout or failure → emit event, return 0 with empty stdout
- Triage orchestrate timeout → emit event, fallback to union if available
- Synthesis timeout → emit event, fallback to union
- No specialist output → emit event, return 0

---

## Acceptance Criteria & Validation

### AC-1: Feature Gate Works
- **Status**: Requires testing
- **Requirement**: With `RUFLO_SELF_HEAL_HIVE=false` (or unset), function returns empty stdout, exit 0, zero overhead
- **Test**: `sw-ruflo-adapter-test.sh::self_heal_hive — gate disabled`
- **Verification**: Test passes; grep output contains "pass"

### AC-2: Fail-Open Behavior
- **Status**: Partially tested (gates exist; need full test coverage)
- **Requirement**: When ruflo unavailable OR hive unavailable OR hive_id empty: return 0 with empty stdout
- **Tests**:
  - `self_heal_hive — ruflo unavailable`
  - `self_heal_hive — hive unavailable`
  - `self_heal_hive — empty hive_id skips with warning`
- **Verification**: All 3 gate tests pass

### AC-3: Happy Path Produces Hypothesis
- **Status**: Partially tested (basic structure exists; need full validation)
- **Requirement**: With all gates passed, hive returns non-empty hypothesis text containing "Hypothesis:" and "Verification:" lines, output < 500 chars
- **Test**: `sw-ruflo-adapter-test.sh::self_heal_hive — happy path emits selection`
- **Verification**: Hypothesis text printed to stdout; contains required lines

### AC-4: Integration with sw-loop.sh
- **Status**: Not tested (integration test needed)
- **Requirement**: Hypothesis injected into GOAL with "## Self-Heal Hypothesis (hive-selected)" header; sentinels (<<<, >>>) sanitized
- **Test**: Integration test in sw-loop.sh context
- **Verification**: Next Claude iteration receives clean GOAL without sentinel corruption

### AC-5: Performance Budget
- **Status**: Not tested (performance test needed)
- **Requirement**: When enabled: < 60s total overhead; when disabled: < 1ms overhead
- **Timeouts**: spawn 12s + triage 20s + read 5s + synth 8s + read 5s = 50s max
- **Test**: Performance profiling test
- **Verification**: Profiling output shows timing under budget for both scenarios

### AC-6: Full Test Suite Passes
- **Status**: Not run (pending completion of AC-1 through AC-5)
- **Requirement**: `npm test` exit code 0; no regressions in other tests
- **Test**: Full `npm test` suite
- **Verification**: All tests pass; no new failures

---

## Remaining Work

### Task 1: Complete Unit Test Suite
**Files Modified**: `scripts/sw-ruflo-adapter-test.sh` (add sections after line 4500)

**Subtasks**:
1. Input bounding tests
   - Error > 8000 bytes → head -c truncates cleanly
   - Changed files > 2000 bytes → head -c truncates cleanly
   - UTF-8 multibyte safety verified

2. Sentinel sanitization tests
   - Mock hypothesis with <<<, >>> embedded
   - Verify sentinels stripped before injection

3. Event correctness tests
   - Verify all event types (self_heal_hive_start, complete, failed, etc.)
   - Verify event fields (max_agents, namespace, pipeline_id, hive_id, synthesis mode)

4. Error path tests
   - Triage timeout (orchestrate exit != 0)
   - Synthesis timeout
   - Empty namespace (no specialist output)
   - Missing key (synthesis didn't write)

**Acceptance**: All 4 subtasks have passing tests  
**Estimate**: 1-2 hours

### Task 2: Integration Test
**Files**: New test section in `scripts/sw-ruflo-adapter-test.sh` or new file

**Requirements**:
1. Mock ruflo functions (spawn, orchestrate, hive-mind memory)
2. Simulate full flow: gate → spawn → triage → synthesis → return
3. Verify hypothesis injected into GOAL in sw-loop.sh context
4. Test GOAL corruption prevention

**Acceptance**: 
- Test captures full hypothesis flow
- Verifies next Claude prompt receives clean GOAL
- Covers success + fallback + timeout scenarios

**Estimate**: 2-3 hours

### Task 3: Performance Test
**Files**: New test section in `scripts/sw-ruflo-adapter-test.sh` or new file

**Requirements**:
1. Measure overhead when `RUFLO_SELF_HEAL_HIVE=false` (< 1ms)
2. Measure overhead when enabled with mocked ruflo (< 60s)
3. Report timing for both scenarios

**Acceptance**: 
- Disabled: < 1ms
- Enabled: < 60s (50s actual + 10s buffer)
- Timing report generated

**Estimate**: 1-2 hours

### Task 4: Full Test Suite Validation
**Command**: `npm test`

**Requirements**:
- Exit code 0
- All tests pass
- No regressions in loop/memory/plugin test suites
- Self-heal hive tests all pass

**Acceptance**: `npm test` completes with exit 0

**Estimate**: 10-15 minutes (runtime) + diagnosis if failures

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Hive spawn timeout (12s) | Medium | High | Non-fatal: falls back to diagnose_failure |
| Triage orchestrate timeout (20s) | Medium | High | Non-fatal: falls back to union if available |
| Synthesis timeout (8s) | Low | Medium | Non-fatal: fallback emits union |
| Malformed hypothesis corrupts GOAL | Low | High | Sanitize <<<, >>> sentinels |
| Performance overhead exceeds 60s | Low | Medium | Profile in real conditions |
| Regression in other tests | Medium | High | Full `npm test` before merge |
| Ruflo unavailable in CI | Low | Low | Fail-open: continue with diagnose_failure |

**Mitigation Strategy**: All failures are non-fatal; loop continues with existing diagnostic layers (diagnose_failure, memory fix lookup, Claude analysis).

---

## Definition of Done

### For This Plan Stage (Complete)

- [x] Implementation analysis complete
- [x] Architecture documented with component diagram and interface contracts
- [x] Acceptance criteria clearly defined with test locations
- [x] Remaining work broken down into 4 concrete tasks
- [x] Risk assessment completed
- [x] No contradictions between claimed status and actual work

### For Build → Test Stages (Pending)

- [ ] Unit tests complete (AC-1, AC-2, AC-3)
- [ ] Integration test complete (AC-4)
- [ ] Performance test complete (AC-5)
- [ ] `npm test` passes (AC-6)

---

## Next Steps

### Plan Approval (Current Stage)
1. Review this plan document
2. Validate risk assessment
3. Approve performance budget (50s overhead when enabled)
4. Proceed to Design stage

### Build Stage
1. Implement Task 1 (unit tests)
2. Implement Task 2 (integration test)
3. Implement Task 3 (performance test)
4. Execute Task 4 (npm test validation)

### Test & Review Stages
1. Automated: CI runs all tests
2. Manual: Trigger test failure and verify hive hypothesis injection
3. Code review: 2+ approvals
4. Feature flag remains `false` until ops approval

---

## Appendix: File Locations & References

**Implementation Files**:
- `scripts/lib/ruflo-adapter.sh:1811-2004` — ruflo_execute_self_heal_hive()
- `scripts/sw-loop.sh:2703-2717` — Integration and GOAL injection

**Test Files**:
- `scripts/sw-ruflo-adapter-test.sh:4244-4500+` — Existing tests
- `scripts/sw-ruflo-adapter-test.sh` (new sections) — Remaining unit/integration/performance tests

**Configuration**:
- Feature flag: `RUFLO_SELF_HEAL_HIVE` (default: false)
- Environment: `RUFLO_AVAILABLE`, `RUFLO_HIVE_AVAILABLE`, `RUFLO_HIVE_ID`

**Related**:
- `scripts/sw-loop.sh:939-1050` — diagnose_failure() (fallback layer)
- `scripts/sw-memory.sh` — memory_closed_loop_inject() (fallback layer)
- `.claude/tasks.md` — Task checklist (existing)

---

**Generated by Plan phase agent**  
**Branch**: feat/feat-ruflo-03-1-self-heal-hypothesis-hiv-422  
**Timestamp**: 2026-05-04T21:25:00Z
