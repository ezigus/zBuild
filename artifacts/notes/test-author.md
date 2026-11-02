# test-author notes — issue #1805 (round 2 fix, pass 3)

## Status: making targeted fixes based on round-2 checker findings

## Checker findings — specific fixes

### SPEC-1 (resume-rehydrate-test.sh)
- Checker: paths 2 and 3 have events files "never populated" → vacuous 0==0.
- Fix:
  1. Add `touch "$S1P2_EVENTS_JSONL"` (and path 3) BEFORE the runner
  2. Remove `if [[ -f ]]; then` guard — use direct jq
  3. ADD `assert_eq "1" "$_s1p2_build_starts"` — build must dispatch; fails before fix

### SPEC-3 (from-stage-rehydrate-test.sh)
- Checker: no runner invocation visible, no file-exists check.
- Assessment: BOTH present in current file (runner lines 91-106, assert_file_exists lines 111-113).
- Fix: leave as-is.

### SPEC-4 (from-stage-rehydrate-test.sh)
- Checker: no assert_contains for stderr stage name.
- Assessment: already present (lines 198-201). Leave as-is.

### SPEC-5 (resume-rehydrate-test.sh)
- Fix: replace "artifact" with "3.6"; replace "exit 1" with "_runner_resume_rehydrate"

### SPEC-6 (resume-rehydrate-test.sh)
- Fix: add "Stage-authoring" check; change "new run" to "new runs"

### SPEC-12 (resume-rehydrate-test.sh)
- Fix: remove ZBUILD_CYCLES_ENABLED=0; add assert_gt for cycled stage.start

### SPEC-13 (from-stage-rehydrate-test.sh)
- Fix: replace install-only with install+run+assert (run fresh pipeline, check intake dispatched)

### SPEC-13 (resume-loop-state-test.sh)
- Fix: add assert_gt "$_SPEC7_FIRST_ITER" "-1" before file content check

### SPEC-13 (resume-entry-points-test.sh)
- Fix: replace install-only with install+run+assert

## Key facts

### artifact-snapshot-coverage template
- stages: intake (roles:[intake]) + cyc (type:cycle, stages:[cycled], max_iter:1, on_max:continue)
- stage_definitions: cycled (roles:[builder])
- cycle until: cycled.verdict == pass (mock writes verdict=pass → converges after 1 iter)
- mock_plugin_factory "cycled" "agent" 0 "" "builder" ✓

### assert_gt signature: assert_gt desc actual threshold → checks actual -gt threshold

### ZBUILD_CYCLES_ENABLED=0 disables cycles; removing enables them
- artifact-snapshot-runner-test.sh runs without it and cycles work ✓

## What is NOT changed (already correct)
- SPEC-3: runner invocation + assert_file_exists already present
- SPEC-4: stderr assert_contains already present
- SPEC-9: all three paths have real runner invocations + file-exists assertions
