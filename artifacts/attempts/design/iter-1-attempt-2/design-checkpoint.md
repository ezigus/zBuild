# Design Checkpoint — Issue #1801 (iteration 3)

## Files read this iteration
- design.md (prior design — complete, adding 7 scope files + 2 supersedes + redesigning SPEC-17/SPEC-2/SPEC-8)
- tests/unit/orch-sequential-retired-guard-test.sh — guard excludes guard itself + docs/adr/ + tests/golden/, NOT orch-backend-misconfigured-test.sh
- tests/unit/event-schema-emitted-coverage-test.sh — checks all emitted literal types are in composed known set
- config/event-schema.json — confirmed: no orch.backend.misconfigured, no plugin.run.timed_out
- core/plugin-registry/lifecycle.sh:487 — set -m called in runner shell (leaks monitor mode)
- tests/integration/runner-release-exit-paths-test.sh:375 — SPEC-6b: child ignoring TERM must not outlive run
- tests/unit/stdin-spawn-guard-test.sh:30 — pins orch-mock's bash -c "$task_body" .* </dev/null
- plugins/tool/orch-mock/plugin.sh:97 — bash -c "$task_body" has NO </dev/null (must be fixed)
- tests/unit/design-prompt-scope-charter-test.sh:93-94 — T6 greps design stage for first timeout_s, expects 600; stage_timeout_s=3900 comes first now

## Key conclusions

### SPEC-17 (tautology)
Acceptance-gate says SPEC-17 assertion just checks if orch-mock/plugin.sh exists — always true.
Fix: REMOVE SPEC-17 from design. The backend-agnostic coverage is structural (lifecycle.sh above
backend layer) and is already proven by SPEC-1's test which runs under orch-mock or bash-parallel.

### SPEC-8 (guard not passing at head)
orch-sequential-retired-guard-test.sh guard excludes: docs/adr/, tests/golden/, itself.
It does NOT exclude orch-backend-misconfigured-test.sh which contains "orch-sequential" at line 6
in a comment. Fix: update SPEC-8 description to say the guard must also exclude
tests/unit/orch-backend-misconfigured-test.sh.

### event-schema.json missing orch.backend.misconfigured and plugin.run.timed_out
Both emitted in core (contract.sh and lifecycle.sh). Neither registered in event-schema.json.
Must add SPEC-18[code] for this. Add config/event-schema.json and 
tests/unit/event-schema-emitted-coverage-test.sh to scope.

### set -m leaks monitor mode  
lifecycle.sh:487 calls `set -m` in the calling shell (not a subshell). Even though `set +m`
follows at line 501, race conditions or error paths may leave -m set. The implementation must
wrap the set -m / process group management in a way that cannot leak. Runner-job-control-abort-
test.sh is not in scope — add it.

### SPEC-2 / SPEC-6b: external SIGTERM path broken
set -m isolates hook in its own process group. External SIGTERM to runner no longer propagates
to hook's children. runner-release-exit-paths-test.sh SPEC-6b fails. Fix: update SPEC-2 to
require that external kill of the runner also kills isolated hook process groups. Add
tests/integration/runner-job-control-abort-test.sh to scope.

### orch-mock stdin close
plugins/tool/orch-mock/plugin.sh line 97: `bash -c "$task_body"` has no </dev/null.
stdin-spawn-guard-test.sh pins the pattern `bash -c "$task_body" .* </dev/null`.
Fix: add plugins/tool/orch-mock/plugin.sh to scope + supersedes entry for orch-mock.

### design-prompt-scope-charter-test.sh T6
T6 greps design stage in simple.yaml for first timeout_s, expects 600. After change,
stage_timeout_s: 3900 appears first. T6 fails with got: 3900.
Fix: add file to scope + supersedes entry explaining T6 must check stage_timeout_s=3900.

### golden files
tests/golden/full-pipeline/event-sequence.golden and tests/golden/parity/event-sequence.golden
flagged by shape-floor. Both need to be in scope for build stage to verify/update.

## What is still unresolved
- Whether golden files actually need content updates (build stage determines)
- Whether set -m requires storing hook PID in SIGTERM handler or a different approach

## Writing final design.md now
