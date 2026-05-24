# Stream 3: Capabilities + Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Read plan format notes at the bottom before starting.

**Goal:** Decompose 2 bash god-files (6,591 lines total), adopt shared test harness, add Claude Code MCP server + 4 skills + 1 enhanced hook.

**Architecture:**

- **Bash Decomposition:** Modular source pattern (source sub-files from main, export all functions). No behavior change, pure structural reorganization.
- **Test Harness:** Central `test-helpers.sh` exists (100+ lines). Standardize all 128 test scripts to source it instead of defining helpers locally.
- **MCP Server:** Lightweight HTTP wrapper around Skipper API at `http://127.0.0.1:4200/mcp`. Register in `.claude/settings.json` as MCP server.
- **Skills:** Four new markdown files in `.claude/skills/` implementing /pipeline-monitor, /fleet-overview, /agent-debug, /cost-report (inline Claude Code calls).
- **Hooks:** New hook fires on Skipper agent crash, captures diagnostics to memory system.

**Tech Stack:** Bash 3.2, Claude Code skills/hooks, MCP protocol, Shipper API

**Estimated Scope:** 22 tasks, ~3-4 days parallel execution with small team (2-3 agents)

---

## Phase 1: Bash Cleanup Foundation (6 tasks)

### Task 1.1: Decompose pipeline-stages.sh — Part A (intake, plan, design)

**Objective:** Extract `stage_intake()`, `stage_plan()`, `stage_design()` (first 950 lines) into new file.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages-intake.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages.sh`

**Steps:**

1. Read pipeline-stages.sh lines 1-950 (headers, helpers, first 3 stage functions)
2. Extract lines 1-163 (file header + helper functions: `prune_context_section()`, `guard_prompt_size()`, `_safe_base_log()`, `_safe_base_diff()`, `show_stage_preview()`) to new file with module guard
3. Extract lines 164-730 (stage_intake function) to new file
4. Extract lines 731-951 (stage_plan, stage_design functions) to new file
5. In original pipeline-stages.sh, replace extracted content with: `source "${SCRIPT_DIR}/lib/pipeline-stages-intake.sh"`
6. Add guard at top: `[[ -n "${_PIPELINE_STAGES_INTAKE_LOADED:-}" ]] && return 0; _PIPELINE_STAGES_INTAKE_LOADED=1`
7. Run: `bash -n scripts/lib/pipeline-stages-intake.sh` (syntax check)
8. Commit: `git add scripts/lib/pipeline-stages-intake.sh scripts/lib/pipeline-stages.sh && git commit -m "refactor(pipeline): decompose intake, plan, design stages into pipeline-stages-intake.sh"`

**Notes:**

- Don't remove from original yet—we'll update the main file in a separate task
- Extract helpers as well (they're shared but we'll consolidate later)
- Module guard pattern: `[[ -n "${_PIPELINE_STAGES_INTAKE_LOADED:-}" ]] && return 0; _PIPELINE_STAGES_INTAKE_LOADED=1`

---

### Task 1.2: Decompose pipeline-stages.sh — Part B (build, test)

**Objective:** Extract `stage_test_first()`, `stage_build()`, `stage_test()` (~800 lines) into new file.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages-build.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages.sh`

**Steps:**

1. Read pipeline-stages.sh lines 952-1458 (stage_test_first, stage_build, stage_test)
2. Create new file with module guard
3. Copy only the three stage functions (no duplicate helpers)
4. Source helper functions from pipeline-stages-intake.sh at top: `source "${SCRIPT_DIR}/lib/pipeline-stages-intake.sh"`
5. Update main pipeline-stages.sh to source this file
6. Run syntax check
7. Commit: `git add scripts/lib/pipeline-stages-build.sh scripts/lib/pipeline-stages.sh && git commit -m "refactor(pipeline): decompose build, test stages into pipeline-stages-build.sh"`

---

### Task 1.3: Decompose pipeline-stages.sh — Part C (review, compound_quality)

**Objective:** Extract `stage_review()`, `stage_compound_quality()`, `stage_audit()` (~400 lines) into new file.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages-review.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages.sh`

**Steps:**

1. Read pipeline-stages.sh lines 1459-1961 (stage_review, stage_compound_quality, stage_audit)
2. Create new file with module guard
3. Copy the three stage functions
4. Source helpers from intake file
5. Update main pipeline-stages.sh to source this file
6. Run syntax check
7. Commit: `git add scripts/lib/pipeline-stages-review.sh scripts/lib/pipeline-stages.sh && git commit -m "refactor(pipeline): decompose review, compound_quality, audit stages into pipeline-stages-review.sh"`

---

### Task 1.4: Decompose pipeline-stages.sh — Part D (pr, merge, deploy)

**Objective:** Extract `stage_pr()`, `stage_merge()`, `stage_deploy()` (~1,100 lines) into new file.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages-delivery.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages.sh`

**Steps:**

1. Read pipeline-stages.sh lines 1962-2853 (stage_pr, stage_merge, stage_deploy)
2. Create new file with module guard
3. Copy the three stage functions
4. Source helpers from intake file
5. Update main pipeline-stages.sh to source this file
6. Run syntax check
7. Commit: `git add scripts/lib/pipeline-stages-delivery.sh scripts/lib/pipeline-stages.sh && git commit -m "refactor(pipeline): decompose pr, merge, deploy stages into pipeline-stages-delivery.sh"`

---

### Task 1.5: Decompose pipeline-stages.sh — Part E (validate, monitor)

**Objective:** Extract `stage_validate()`, `stage_monitor()` (~300 lines) into new file.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages-monitor.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages.sh`

**Steps:**

1. Read pipeline-stages.sh lines 2854-end (stage_validate, stage_monitor)
2. Create new file with module guard
3. Copy the two stage functions
4. Source helpers from intake file
5. Update main pipeline-stages.sh to source this file
6. Run syntax check
7. Commit: `git add scripts/lib/pipeline-stages-monitor.sh scripts/lib/pipeline-stages.sh && git commit -m "refactor(pipeline): decompose validate, monitor stages into pipeline-stages-monitor.sh"`

---

### Task 1.6: Finalize pipeline-stages.sh

**Objective:** Reduce pipeline-stages.sh to ~100 lines (loader + exports).

**Files:**

- Edit: `/Users/sethford/Documents/shipwright/scripts/lib/pipeline-stages.sh`

**Steps:**

1. Read current pipeline-stages.sh
2. Keep file header, module guard, defaults section
3. Delete all duplicated helpers (keep only in intake sub-file)
4. Add five source statements at bottom (for the five stage files)
5. Add final section exporting stage function list:
   ```bash
   # Export all available stages
   export PIPELINE_STAGES="intake plan design test_first build test review compound_quality audit pr merge deploy validate monitor"
   ```
6. Final file should be ~100-120 lines
7. Run: `bash -n scripts/lib/pipeline-stages.sh` (syntax check)
8. Verify by running sw-pipeline-test.sh (should pass without changes)
9. Commit: `git add scripts/lib/pipeline-stages.sh && git commit -m "refactor(pipeline): consolidate pipeline-stages.sh to loader (100 lines)"`

---

## Phase 2: Loop Decomposition (4 tasks)

### Task 2.1: Decompose sw-loop.sh — Part A (loop-iteration.sh)

**Objective:** Extract single-iteration logic (~600 lines).

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/loop-iteration.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/sw-loop.sh`

**Steps:**

1. Read sw-loop.sh, identify functions for single iteration:
   - `select_adaptive_model()`
   - `select_audit_model()`
   - `accumulate_loop_tokens()`
   - `write_loop_tokens()`
   - `validate_claude_output()`
   - `check_fatal_error()`
   - `check_progress()`
   - `check_completion()`
   - `run_test_gate()`
   - `write_error_summary()`
   - `run_audit_agent()`
   - `run_quality_gates()`
   - `compose_prompt()`
   - Full iteration loop logic from main function
2. Create new file with module guard `_LOOP_ITERATION_LOADED`
3. Copy listed functions to new file
4. Source helpers in sw-loop.sh: `source "${SCRIPT_DIR}/lib/loop-iteration.sh"`
5. Replace iteration logic in sw-loop.sh main loop with call to extracted function
6. Syntax check both files
7. Commit: `git add scripts/lib/loop-iteration.sh scripts/sw-loop.sh && git commit -m "refactor(loop): extract single-iteration logic into loop-iteration.sh"`

---

### Task 2.2: Decompose sw-loop.sh — Part B (loop-convergence.sh)

**Objective:** Extract convergence detection logic (~400 lines).

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/loop-convergence.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/sw-loop.sh`

**Steps:**

1. Extract convergence-related functions:
   - `check_circuit_breaker()`
   - `check_max_iterations()`
   - `diagnose_failure()`
   - `detect_stuckness()`
   - `record_iteration_stuckness_data()`
   - `compose_audit_section()`
   - `check_definition_of_done()`
   - `track_iteration_velocity()`
   - `compute_velocity_avg()`
2. Create new file with module guard `_LOOP_CONVERGENCE_LOADED`
3. Copy functions
4. Source in sw-loop.sh
5. Syntax check
6. Commit: `git add scripts/lib/loop-convergence.sh scripts/sw-loop.sh && git commit -m "refactor(loop): extract convergence detection into loop-convergence.sh"`

---

### Task 2.3: Decompose sw-loop.sh — Part C (loop-restart.sh)

**Objective:** Extract session restart logic (~300 lines).

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/loop-restart.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/sw-loop.sh`

**Steps:**

1. Extract session restart functions:
   - `initialize_state()`
   - `resume_state()`
   - `write_state()`
   - `append_log_entry()`
   - Logic for session restart after exhaustion
2. Create new file with module guard `_LOOP_RESTART_LOADED`
3. Copy functions
4. Source in sw-loop.sh
5. Syntax check
6. Commit: `git add scripts/lib/loop-restart.sh scripts/sw-loop.sh && git commit -m "refactor(loop): extract session restart logic into loop-restart.sh"`

---

### Task 2.4: Decompose sw-loop.sh — Part D (loop-progress.sh)

**Objective:** Extract progress.md management (~200 lines).

**Files:**

- Create: `/Users/sethford/Documents/shipwright/scripts/lib/loop-progress.sh`
- Edit: `/Users/sethford/Documents/shipwright/scripts/sw-loop.sh`

**Steps:**

1. Extract progress tracking functions:
   - `write_progress()`
   - `manage_context_window()`
   - `git_commit_count()`, `git_recent_log()`, `git_diff_stat()`, `git_auto_commit()`
   - Progress file write logic
2. Create new file with module guard `_LOOP_PROGRESS_LOADED`
3. Copy functions
4. Source in sw-loop.sh
5. Syntax check
6. Commit: `git add scripts/lib/loop-progress.sh scripts/sw-loop.sh && git commit -m "refactor(loop): extract progress tracking into loop-progress.sh"`

---

## Phase 3: Test Harness Adoption (1 task + 3 parallel)

### Task 3.1: Verify test-helpers.sh completeness

**Objective:** Ensure test-helpers.sh has all common assertion/setup patterns.

**Files:**

- Read: `/Users/sethford/Documents/shipwright/scripts/lib/test-helpers.sh`

**Steps:**

1. Read full test-helpers.sh to see what's exported
2. Verify it has: colors, counters, assert_pass/fail/eq/contains/contains_regex/gt/json_key, setup_test_env, cleanup_test_env, print_test_header, print_test_results, mock helpers
3. If any missing patterns found, add them to test-helpers.sh
4. Commit if changes: `git add scripts/lib/test-helpers.sh && git commit -m "refactor(tests): ensure test-helpers.sh has all common patterns"`

---

### Task 3.2: Adopt test harness — Batch A (scripts/\*-test.sh [A-H])

**Objective:** Update first 32 test scripts to source test-helpers.sh.

**Files:**

- Edit: All test scripts matching pattern `scripts/sw-*-test.sh` where name starts with A-H (32 files)

**Steps:**

1. For each test script:
   a. Read first 50 lines
   b. If it defines its own `assert_pass()`, `assert_fail()`, etc., mark for replacement
   c. Add at top (after shebang and after `SCRIPT_DIR=...`): `source "$SCRIPT_DIR/lib/test-helpers.sh"`
   d. Remove duplicate helper function definitions (keep custom ones if unique)
   e. Syntax check: `bash -n <file>`
2. Bulk commit: `git add scripts/sw-*-test.sh && git commit -m "refactor(tests): adopt test-helpers.sh in batch A (32 scripts)"`

**Note:** Can be done in parallel with next batches. Each batch can be a separate agent.

---

### Task 3.3: Adopt test harness — Batch B (scripts/\*-test.sh [I-P])

**Objective:** Update next 32 test scripts to source test-helpers.sh.

**Files:**

- Edit: All test scripts starting with I-P (32 files)

**Steps:**

1. Same as Task 3.2
2. Bulk commit: `git add scripts/sw-*-test.sh && git commit -m "refactor(tests): adopt test-helpers.sh in batch B (32 scripts)"`

---

### Task 3.4: Adopt test harness — Batch C (scripts/\*-test.sh [Q-Z])

**Objective:** Update remaining test scripts to source test-helpers.sh.

**Files:**

- Edit: All remaining test scripts (64 files)

**Steps:**

1. Same as Task 3.2
2. Bulk commit: `git add scripts/sw-*-test.sh && git commit -m "refactor(tests): adopt test-helpers.sh in batch C (64 scripts)"`

---

## Phase 4: Claude Code Capabilities (7 tasks)

### Task 4.1: Create MCP server wrapper

**Objective:** Register Skipper API as MCP server for Claude Code.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/.claude/mcp/skipper-server.sh`
- Edit: `/Users/sethford/Documents/shipwright/.claude/settings.json`

**Steps:**

1. Create wrapper script that:
   - Checks if `http://127.0.0.1:4200` is reachable
   - Translates MCP tool calls to HTTP POST to `/mcp` endpoint
   - Returns tool responses
2. Add minimal bash script that acts as MCP bridge (see MCP protocol docs for format)
3. In settings.json, add under `mcpServers`:
   ```json
   "skipper": {
     "command": "bash",
     "args": [".claude/mcp/skipper-server.sh"],
     "description": "Skipper Agent OS API"
   }
   ```
4. Test: Try calling a tool from Claude Code terminal
5. Commit: `git add .claude/mcp/skipper-server.sh .claude/settings.json && git commit -m "feat(mcp): register Skipper API as MCP server for Claude Code"`

**Notes:**

- If Skipper is not running, server should gracefully fail with helpful message
- See MCP protocol in Skipper docs for exact message format

---

### Task 4.2: Create pipeline-monitor skill

**Objective:** /pipeline-monitor — check pipeline progress, surface blockers.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/.claude/skills/pipeline-monitor.md`

**Steps:**

1. Create skill file with:
   - Heading: `# Pipeline Monitor`
   - Description: "Real-time pipeline progress tracking and blocker detection"
   - Implementation that:
     - Calls `shipwright status --json` to get current pipeline state
     - Reads `.claude/pipeline-state.md` for detailed stage info
     - Checks for blockers (failed stages, hung iterations)
     - Displays in user-friendly format with progress bars
2. Include inline Claude Code that uses bash to run shipwright commands
3. Commit: `git add .claude/skills/pipeline-monitor.md && git commit -m "feat(skills): add pipeline-monitor skill"`

---

### Task 4.3: Create fleet-overview skill

**Objective:** /fleet-overview — multi-repo fleet status.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/.claude/skills/fleet-overview.md`

**Steps:**

1. Create skill file with:
   - Heading: `# Fleet Overview`
   - Description: "Multi-repo fleet status, worker pool, per-repo queue"
   - Implementation that:
     - Reads fleet-config.json
     - Calls `shipwright fleet` status command
     - Shows per-repo pipeline queue depth
     - Shows worker pool utilization
2. Commit: `git add .claude/skills/fleet-overview.md && git commit -m "feat(skills): add fleet-overview skill"`

---

### Task 4.4: Create agent-debug skill

**Objective:** /agent-debug — debug stuck/failing Skipper agent.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/.claude/skills/agent-debug.md`

**Steps:**

1. Create skill file with:
   - Heading: `# Agent Debug`
   - Description: "Diagnose stuck or failing Skipper agents"
   - Implementation that:
     - Takes agent ID as input
     - Calls Skipper API to fetch agent logs
     - Reads memory system for failure patterns
     - Checks heartbeat status
     - Suggests recovery steps
2. Commit: `git add .claude/skills/agent-debug.md && git commit -m "feat(skills): add agent-debug skill"`

---

### Task 4.5: Create cost-report skill

**Objective:** /cost-report — token usage and cost analysis.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/.claude/skills/cost-report.md`

**Steps:**

1. Create skill file with:
   - Heading: `# Cost Report`
   - Description: "Token usage and cost analysis for pipelines"
   - Implementation that:
     - Calls `shipwright cost show` for current state
     - Reads cost tracking files
     - Shows breakdown by pipeline/stage
     - Alerts if approaching budget
2. Commit: `git add .claude/skills/cost-report.md && git commit -m "feat(skills): add cost-report skill"`

---

### Task 4.6: Create agent-crash detection hook

**Objective:** Auto-capture diagnostics when Skipper agent crashes.

**Files:**

- Create: `/Users/sethford/Documents/shipwright/.claude/hooks/agent-crash-capture.sh`
- Edit: `/Users/sethford/Documents/shipwright/.claude/settings.json`

**Steps:**

1. Create hook script that:
   - Monitors heartbeat files in `~/.shipwright/heartbeats/`
   - Detects when an agent heartbeat file goes stale (>2 minutes old)
   - Captures:
     - Agent logs (last 50 lines)
     - Last iteration output
     - Error summary
     - System state (memory, CPU)
   - Writes diagnostic bundle to memory system: `~/.shipwright/memory/<repo>/<agent-id>.crash-dump.json`
   - Emits event: `agent_crash` with agent_id, reason
2. In settings.json, register hook for new event type or use periodic check
3. Test: Kill an agent, verify diagnostics captured
4. Commit: `git add .claude/hooks/agent-crash-capture.sh .claude/settings.json && git commit -m "feat(hooks): add agent-crash-capture diagnostics hook"`

**Notes:**

- Graceful fallback if heartbeat files not found
- Don't block agent execution, run async
- Compress old crash dumps to avoid disk bloat

---

### Task 4.7: Wire Refined Depths brand implementation

**Objective:** Execute Refined Depths plan (dashboard + docs styling).

**Files:**

- Edit: All dashboard HTML/CSS files (in `dashboard/public/`)
- Edit: All documentation files (in `docs/`)

**Steps:**

1. Read: `docs/plans/2026-03-01-refined-depths-implementation.md` (separate doc)
2. Apply color scheme changes to dashboard CSS/HTML
3. Apply typography and spacing updates
4. Update documentation site styling
5. Commit all changes: `git add dashboard/ docs/ && git commit -m "brand: apply Refined Depths design system"`

---

## Phase 5: Verification & Integration (4 tasks)

### Task 5.1: Run full test suite on decomposed pipeline-stages

**Objective:** Verify all 19 stages work correctly after decomposition.

**Files:**

- Run: `bash scripts/sw-lib-pipeline-stages-test.sh`
- Run: `bash scripts/sw-pipeline-test.sh`

**Steps:**

1. Run existing stage test suite: `bash scripts/sw-lib-pipeline-stages-test.sh`
2. Run full pipeline e2e test: `bash scripts/sw-pipeline-test.sh`
3. If failures, debug and fix (likely just import issues)
4. Commit any fixes: `git add ... && git commit -m "fix(pipeline): correct stage decomposition imports"`

---

### Task 5.2: Run full test suite on decomposed loop

**Objective:** Verify loop iteration, convergence, restart, progress all work.

**Files:**

- Run: `bash scripts/sw-loop-test.sh`

**Steps:**

1. Run loop test suite: `bash scripts/sw-loop-test.sh`
2. If failures, fix imports/sourcing
3. Commit fixes if needed

---

### Task 5.3: Run full test suite on test-harness adoption

**Objective:** Verify all 128 test scripts still pass with shared harness.

**Files:**

- Run: `npm test` (runs all test suites)

**Steps:**

1. Run full test suite: `npm test`
2. Should see ~95+ tests pass
3. If failures, likely missing helpers — add to test-helpers.sh
4. Commit fixes

---

### Task 5.4: Integration test — MCP server + skills

**Objective:** Verify new Claude Code features work end-to-end.

**Files:**

- Manual: Test in Claude Code terminal

**Steps:**

1. Start Skipper locally: `skipper start` (if available)
2. In Claude Code, try invoking skill: `/pipeline-monitor`
3. Verify skill executes and returns output
4. Try other skills: `/fleet-overview`, `/agent-debug`, `/cost-report`
5. If issues, debug hook/skill implementations
6. Document any limitations in .claude/CLAUDE.md

---

## Phase 6: Documentation & Final (1 task)

### Task 6.1: Update .claude/CLAUDE.md with new capabilities

**Objective:** Document new skills, hooks, and MCP server.

**Files:**

- Edit: `/Users/sethford/Documents/shipwright/.claude/CLAUDE.md`

**Steps:**

1. Add section "Claude Code Skills" listing new skills: pipeline-monitor, fleet-overview, agent-debug, cost-report
2. Add MCP server info: "Skipper API available via MCP server at 127.0.0.1:4200"
3. Add Hook info: "Agent crash detection hook auto-captures diagnostics"
4. Update architecture table if pipeline-stages decomposition changes line counts
5. Commit: `git add .claude/CLAUDE.md && git commit -m "docs: add Stream 3 capabilities to CLAUDE.md"`

---

## Parallel Execution Strategy

**Recommended team composition:** 3 agents

- **Agent 1 (Pipeline Decomposer):** Tasks 1.1–1.6 (bash cleanup for pipeline-stages)
- **Agent 2 (Loop Decomposer):** Tasks 2.1–2.4 (bash cleanup for sw-loop)
- **Agent 3 (Capabilities):** Tasks 3.1–4.7 (test harness + MCP + skills + hooks in parallel with Agents 1–2)

**Merge safety:** Each phase uses different files, no conflicts expected.

**Verification order:**

1. Phases 1–2 complete → Run Task 5.1–5.2
2. Phase 3 complete → Run Task 5.3
3. Phase 4 complete → Run Task 5.4
4. All phases complete → Run Task 6.1

---

## Success Criteria

- [ ] pipeline-stages.sh reduced to ~100 lines (loader only)
- [ ] 5 new stage sub-files created and working (pipeline-stages-intake/build/review/delivery/monitor.sh)
- [ ] sw-loop.sh reduced by ~50% (4 sub-files handling iteration/convergence/restart/progress)
- [ ] All 128 test scripts source test-helpers.sh
- [ ] MCP server registered and functional
- [ ] 4 new skills created and callable from Claude Code
- [ ] Agent crash hook implemented and tested
- [ ] All existing tests pass (no regression)
- [ ] Refined Depths brand applied to dashboard + docs

---

## Plan Format Notes

- **File paths:** All absolute paths (`/Users/sethford/Documents/shipwright/...`)
- **Commits:** One per logical chunk, frequent (every task or subtask)
- **Testing:** After each phase, run relevant test suite
- **Bash 3.2:** No bashisms in new files (no `declare -A`, no `readarray`, etc.)
- **Sourcing pattern:** Use `source "${SCRIPT_DIR}/lib/file.sh"` with guard `[[ -n "${_FILE_LOADED:-}" ]] && return 0; _FILE_LOADED=1`
- **No new behavior:** Decomposition is pure structural, all tests should pass unchanged
- **Tasks can run in parallel:** Phases 1, 2, 3 touch different files. Use `--worktree` if needed for true isolation.
