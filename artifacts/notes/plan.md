# Plan notes — issue #1801

## Reading the issue

Issue: stage timeouts silently stop applying — fallback orchestrator ignores --timeout, hung stage reports success.

### Already done (do not rebuild)
- Whole-stage `timeout_s:` per stage in templates (ADR-063 amendment), enforced in `plugin_hook_call` via lifecycle.sh watchdog.
- `stage_timeout_s` / `ZBUILD_STAGE_TIMEOUT_S` superseded — do not touch.

### Problems still present
1. `orch-sequential` ignores `--timeout`; `orch_load_backend` silently falls back to it when backend not found; `_orch_load_backend` defaults to sequential when config unreadable, discards warning. No `backend.degraded` event.
2. Strategies (`_strategy_run_map`, `_fanout`, `_sequential`) pass `orch_collect --timeout "${ZBUILD_ORCH_TIMEOUT:-300}"` — cuts off stages whose `timeout_s:` is > 300 s.
3. `_runner_dispatch_always_run` reads `router.timeout_s` (fallback `ZBUILD_RELEASE_TIMEOUT:-30`) as a whole-stage bound for teardown stages — wrong; should use `timeout_s:`.
4. Hand-rolled TERM→2s→KILL in `_runner_dispatch_always_run`; hand-rolled TERM/0.5s/KILL in `_orch_local_kill_slot`; `zbuild_pg_kill` exists as shared helper and should be used.

### Decisions (binding)
1. `orch-sequential` is retired — plugin dir + golden deleted; no built-in lookup; sequential/orch-sequential treated as unknown.
2. Missing or unreadable backend → `misconfigured` hard error naming backend. No fallback.
3. No flat collect deadline — strategies drop `ZBUILD_ORCH_TIMEOUT`; `timeout_s:` is the only limit.
4. `router.timeout_s` bounds one model call only. `always_run` stages use `timeout_s:` (30s/120s in shipped templates).
5. Kill via `zbuild_pg_kill` in both places.

### Areas
- `core/orch/contract.sh` — backend loader hardening
- `core/pipeline/strategies/map.sh`, `fanout.sh`, `sequential.sh` — remove ZBUILD_ORCH_TIMEOUT
- `core/pipeline/runner.sh` — fix always_run dispatch
- `core/orch/local_engine.sh` — fix slot kill
- `scripts/lib/proc-group.sh` — shared kill helper (already exists)
- `plugins/tool/orch-sequential/` — DELETE
- `tests/golden/orch-sequential-capabilities.golden` — DELETE
- `docs/wiki/Plugins.md`, `docs/wiki/plugins/orch-sequential.md` — remove orch-sequential references
- `plugins/tool/orch-mock/tests/orch-mock-test.sh`, `plugins/tool/orch-ruflo-hive/plugin.sh` — remove orch-sequential comments
- `config/templates/simple.yaml`, `config/templates/deployed.yaml` — move timeout_s: from router: to top-level for release/persist
- `docs/adr/ADR-011.md`, `docs/adr/ADR-017.md` — amend with Enforced by
- `config/adr-enforcement-baseline.txt` — remove ADR-011 and ADR-017

### Test-first requirement
Every implementation step is preceded by its failing test. Scope discovery is step 1 (mandated by acceptance criteria).

## Plan structure decided

13 steps (updated from original after reviewing design findings):

1. Scope discovery
2. Write failing tests — orch-sequential guard + misconfigured config
3. Delete orch-sequential; migrate/delete its tests; remove its lookup; clean all orch-sequential references in wiki + plugin files
4. Write failing tests — hard backend error from installed tree (missing + unreadable)
5. Harden backend loader (remove both fallback paths)
6. Write failing tests — hung stage timed_out, ZBUILD_ORCH_TIMEOUT no longer honored
7. Remove ZBUILD_ORCH_TIMEOUT from strategy collect calls
8. Write failing tests — always_run bounded by timeout_s:, not router.timeout_s
9. Fix always_run dispatch (use timeout_s:, use zbuild_pg_kill); move timeout_s: in templates from router: to top-level
10. Write failing test — local engine kill leaves no orphan
11. Fix local engine slot killer (use zbuild_pg_kill)
12. Amend ADR-011 and ADR-017 (Enforced by entries); remove from adr-enforcement-baseline.txt
13. Verify npm test + npm run lint pass

All acceptance criteria mapped:
- [AC1] hung stage ends timed_out → steps 2+3 (retire orch-sequential) + steps 6+7 (remove flat limit)
- [AC2] stage > 300s completes → steps 6+7
- [AC3] orch-sequential gone, guard test → steps 2+3
- [AC4] missing/unreadable backend → misconfigured, from installed tree → steps 4+5
- [AC5] release/persist bounded by timeout_s: → steps 8+9
- [AC6] kill through zbuild_pg_kill, no orphans → steps 10+11
- [AC7] scope discovery → step 1
- [AC8] ADR-011, ADR-017 Enforced by → step 12
- [AC9] npm test + lint green → step 13

No open questions identified.

## Design findings applied (second pass)

Three gaps found in design.md vs. original plan, now corrected:

1. **Step 3 areas expanded**: SPEC-3 guard fails on any reference outside docs/adr/ — must clean
   docs/wiki/Plugins.md, docs/wiki/plugins/orch-sequential.md, orch-mock and ruflo-hive comments,
   and the G5 block in plugin-artifact-goldens-test.sh.

2. **Step 9 areas expanded**: Both shipped templates declare `timeout_s:` under `router:` for
   release/persist stages; `template_stage_time_limit` reads the top-level key only — templates
   must move those values before the watchdog fix is effective.

3. **Step 12 areas expanded**: `config/adr-enforcement-baseline.txt` must have ADR-011 and ADR-017
   removed; `npm run lint` (lint-adr-enforced-by.sh) requires it once those ADRs carry
   `## Enforced by` sections.

## Design findings applied (third pass — unusable design verdict)

The "unusable" design attempt found two findings:
1. "SPEC-11 covers only plugins/tool/orch-sequential/tests/orch-sequential-test.sh" for R-3
2. No SPEC requires that tests/integration/stage-time-limit-test.sh and tests/unit/map-strategy-test.sh
   are migrated to pass on orch-mock/bash-parallel (vs. just having references stripped)

**Resolution:** The issue's "Not in scope" clause says how fixture tests are migrated is "build's
choice, checked by the full suite (npm test)." AC9 (npm test green) is the operative criterion, not
a specific migration SPEC. However, the plan step 3 was too general for the design to generate
targeted SPECs. Updated step 3 to:
- Explicitly name tests/integration/stage-time-limit-test.sh and tests/unit/map-strategy-test.sh
  in areas
- Distinguish "migrate so the test still passes on the new backend" from "strip the reference and
  leave the test broken" in the description

The 13 steps are otherwise unchanged. No open questions.
