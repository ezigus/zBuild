# Issue Acceptance Notes — #1801

## What I read

- DIFF: only 2 files changed (core/orch/contract.sh, tests/fixtures/templates/always-run-minimal.yaml) — build stage timed out
- TEST VERDICT: fail (818 pass, 2 fail)
- Directly read: fanout.sh, map.sh, sequential.sh, contract.sh (full), runner.sh (always_run section), local_engine.sh, always-run-minimal.yaml, orch-backend-misconfigured-test.sh, always-run-exit-paths-test.sh (SPEC-5 region), orch-sequential-absent-guard-test.sh, ADR-011/ADR-017 (Enforced by grep), adr-enforcement-baseline.txt (grep)

## Per-requirement conclusions

**R-1 MET**: fanout.sh:79, map.sh:338, sequential.sh:62 all use `template_stage_time_limit "$stage"` — not ZBUILD_ORCH_TIMEOUT. SPEC-1 test (`orch-timeout-applies-test.sh`) not in failing list.

**R-2 MET**: `ZBUILD_ORCH_TIMEOUT` only appears in a comment in `orch-timeout-applies-test.sh` (as documentation of old behaviour). Not read in any strategy.

**R-3 MET**: `plugins/tool/orch-sequential/` — NOT FOUND. `tests/golden/orch-sequential-capabilities.golden` — NOT FOUND. Guard test `tests/unit/orch-sequential-absent-guard-test.sh` exists, searches core/plugins/scripts/config/tests/.github, skips itself, skips docs/adr/. Only remaining references outside docs/adr/ are: (a) the guard test itself (explicitly skipped), (b) `docs/audits/...` (outside guard's search scope — acceptable per guard test design). Config file `.github/issues/keepers-manifest.yaml` not checked yet but the guard test searches `.github/` — worth noting.

Wait - the guard test searches `.github/` at line 51. Let me reconsider: is keepers-manifest.yaml in .github? Yes — `.github/issues/keepers-manifest.yaml`. If that file still contains `orch-sequential`, the guard test would fail. But SPEC-3 says keepers-manifest lines 2841/3329/3335/3345 must be cleaned. The "Files this issue's work has changed so far" includes `.github/issues/keepers-manifest.yaml` — so it was changed. And the guard test doesn't appear in the failing list — it passed. So R-3 is MET.

**R-4 UNMET (partial)**: `orch_load_backend` correctly returns 1 with misconfigured disposition for unknown/absent/unreadable backends. BUT `orch-backend-misconfigured-test.sh` sources `contract.sh` directly from the checkout (`$REPO_ROOT/core/orch/contract.sh`) and calls `orch_load_backend` in isolation. The issue explicitly requires "tested from the **installed** tree (`install.sh` layout), not only the checkout." No installed-tree test exists. The function-level behaviour is correct and SPEC-2/SPEC-4/SPEC-10 pass in isolation, but the end-to-end installed-tree requirement is unmet.

**R-5 UNMET**: Two active test failures:
1. `always-run-exit-paths-test.sh` [#1801/SPEC-5] persist hook was not entered — file `spec5p-entered` not found. Runner exited in 0s without entering the persist plugin hook, meaning the always_run persist stage was never dispatched. The timing assertion passed vacuously (0s < 20s), but the hook-entered sentinel is absent.
2. `runner-release-exit-paths-test.sh` [SPEC-5] cleanup not dispatched on hard-kill exit path — regression, `no release from: intake build | marker=`.

**R-6 MET**: `local_engine.sh` `_orch_local_kill_slot` uses `zbuild_pg_kill` (confirmed at lines 43, 135-136, 187, 197). `runner.sh` always-run watchdog uses `zbuild_pg_kill` (lines 2493, 2504). Test [SPEC-6b] passes.

**R-7 UNSURE**: Process requirement — cannot verify from diff whether every test pinning `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s`, `_orch_local_kill_slot` in tests/ was put in scope. No way to verify from the code alone.

**R-8 MET**: `docs/adr/ADR-011-pluggable-backends.md` line 206 has `## Enforced by`. `docs/adr/ADR-017-per-stage-router-config.md` line 431 has `## Enforced by`. Neither ADR is in `config/adr-enforcement-baseline.txt`.

**R-9 UNMET**: TEST VERDICT is `fail`. 2 failing tests. exit_code: 1.

## Verdict

VERDICT: fail
UNMET: R-4, R-5, R-9
UNSURE: R-7
