---
name: pipeline-monitor
description: Check pipeline progress, surface blockers
user_invocable: true
---

# Pipeline Monitor

Check the current Shipwright pipeline status and surface any blockers.

## Instructions

1. Read `.claude/pipeline-state.md` if it exists to get current pipeline state
2. Check for recent pipeline artifacts in `.claude/pipeline-artifacts/`
3. Look at the last 5 git commits to understand recent progress
4. Check if there are any failing tests by running: `npm test 2>&1 | tail -20`
5. Report:
   - Current pipeline stage (intake, plan, build, test, review, pr, etc.)
   - How many iterations have been completed
   - Any blockers (failing tests, missing dependencies, etc.)
   - Estimated remaining work based on stage and iteration count
6. If no pipeline is active, report that and suggest starting one with `shipwright pipeline start`
