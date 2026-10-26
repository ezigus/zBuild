# Design notes — issue #1801 (revision 3)

## What changed from the rejected design

The previous design was rejected for two missing SPEC coverages:
- **R-7** (test scope discovery grep requirement) — not covered by any SPEC
- **R-9** (`npm test` + `npm run lint` green) — not covered by any SPEC

Added to acceptance block:
- **SPEC-8[no-code]**: covers R-7 — documents scope-completeness check via grep, with [no-code]
  status because it is a process/documentation requirement (confirming the scope is correct),
  not a new code behaviour.
- **SPEC-9[no-code]**: covers R-9 — standing quality gate that all delivered code must pass
  `npm test` + `npm run lint`.

## Grep results (R-7 validation)

Ran all required greps against `tests/`:

- `grep -rl 'orch-sequential' tests/` → 8 files, all in scope
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → 2 files, both in scope
- `grep -rl '_orch_local_kill_slot' tests/` → 0 hits
- `grep -rl 'router\.timeout_s' tests/` → 17 files total
  - 2 pin the always-run watchdog bound → in scope
  - 15 test ADR-017 per-stage model-call timeout (unchanged by this issue) → correctly excluded

The 15 excluded `router.timeout_s` files test `template_stage_router_timeout` (per-call model
timeout accessor), NOT the always-run watchdog bound. Spot-checked `core-pipeline-template-test.sh`
lines 493-590 to confirm.

## Key findings (carried from previous work)

### ZBUILD_ORCH_TIMEOUT references (the 300s flat collect deadline)
- `core/pipeline/strategies/sequential.sh:62`
- `core/pipeline/strategies/fanout.sh:79`
- `core/pipeline/strategies/map.sh:338`

Replace with `template_stage_time_limit "$stage"`.

### orch-sequential fallback in contract.sh
- `core/orch/contract.sh:165-181` — fallback to sequential when backend not found
- Must be removed and made fatal.

### _orch_local_kill_slot in local_engine.sh
- `core/orch/local_engine.sh:34-40` — kills wrapper+inner PID directly via `kill`
- Must route through `zbuild_pg_kill` (scripts/lib/proc-group.sh)

### _runner_dispatch_always_run in runner.sh
- `core/pipeline/runner.sh:2463-2465` — reads `_TPL_STAGE_ROUTER_TIMEOUT_${safe}` then falls
  back to `ZBUILD_RELEASE_TIMEOUT:-30`
- Should use `template_stage_time_limit` for watchdog bound
- Line 2493 watchdog also needs `zbuild_pg_kill`

### Templates
Both `config/templates/simple.yaml` and `config/templates/deployed.yaml` declare `timeout_s:`
for release/persist under `router:` block. Must be moved to top-level stage block.

## Revision 3: fixing the two design findings

**Design finding 1** (SPEC-1 missing "names stage and limit"):
- SPEC-1 previously said only "the stage outcome is `timed_out`"
- R-1 explicitly requires "ends `timed_out` naming the stage and the limit"
- Fixed: SPEC-1 now reads "the stage outcome is `timed_out` and the result names both the stage and the limit exceeded"

**Design finding 2** (R-4 unreadable config not covered):
- R-4 has two sub-cases: (a) backend not found — covered by SPEC-2/SPEC-4; (b) backend directory present but config unreadable — not previously covered
- Fixed: Added SPEC-10[code] covering "backend directory present but config unreadable, fails as `misconfigured`"
- SPEC-10 shares test file `tests/integration/orch-backend-misconfigured-test.sh` with SPEC-4 (same test, different fixture scenario)
- No new test file needed; both R-4 sub-cases are tested in the same integration test

## Status: COMPLETE (revision 3)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md
