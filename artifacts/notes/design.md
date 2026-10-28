# Design notes — issue #1801 (revision 12)

## What changed from revision 11

### Issue-acceptance findings (revision 12)

The issue-acceptance stage returned 6 findings:
- Finding 1 (R-5): `always-run-exit-paths-test.sh` fails `[SPEC-5][guard]` tests.
- Finding 2 (R-9): npm test red — 17 integration failures.
- Findings 3–6: pipeline failures (R-1, R-2, R-4, R-6) from incomplete build.

**Root cause — Finding 1 (R-5, SPEC-5):**
`tests/fixtures/templates/always-run-minimal.yaml` has `release.router.timeout_s: 2`
instead of a top-level `release.timeout_s: 2`. `template_stage_time_limits_load` looks
for `timeout_s:` at `ind[$stage] + 2` indent (2 spaces for root-level stages). In the
fixture `router.timeout_s: 2` is at indent 4, not 2. So `template_stage_time_limit "release"`
returns 900 (the default). The watchdog uses 900 s; a 60-second hook completes unchecked.
**Fix**: add `tests/fixtures/templates/always-run-minimal.yaml` to scope; SPEC-5 now
explicitly names this fixture as needing `timeout_s: 2` at the direct stage-block level.

Note: `simple.yaml` already has `release.timeout_s: 30` at the top level (from `ee6aab95`
build commit). The fixture `always-run-minimal.yaml` `extends: simple` but
`template_stage_time_limits_load` reads only the overlay source file, NOT the merged
template — so the fixture's stage block must have its own `timeout_s:`.

**Root cause — Finding 2 (R-9), 17 integration failures:**
`core/orch/contract.sh`'s `_orch_load_backend` still uses `sequential` as the fallback
when `zbuild_config_get_backend` is unavailable or `ZBUILD_ORCHESTRATOR_BACKEND` is unset.
Since `orch-sequential` is now deleted, `orch_load_backend "sequential"` fails with
`_ZBUILD_ORCH_BACKEND_DISPOSITION=misconfigured`. The stubs remain active but useless;
any pipeline run that doesn't explicitly configure a backend via `ZBUILD_ORCHESTRATOR_BACKEND`
fails when the stubs are called. This is the source of the 17 broad integration failures.
**Fix**: Decision 1 is clarified: change the `sequential` fallback in `_orch_load_backend`
to `bash-parallel` (the actual system default), not remove all fallback. This is a code
issue in scope (contract.sh). The design already covers contract.sh.

**Findings 3–6 (R-1, R-2, R-4, R-6):** Implementation incomplete (build timed out after
only committing keepers-manifest.yaml in the second build pass). All affected source files
are in scope. Code issue for the next build pass.

## Key facts carried from revision 11

### always-run-minimal.yaml fixture (NEW scope gap added in revision 12)
File: `tests/fixtures/templates/always-run-minimal.yaml`
Issue: `release.router.timeout_s: 2` (indent 4) — not visible to `template_stage_time_limit`
       which looks for `timeout_s:` at indent 2 (stage-level + 2).
Fix: add `timeout_s: 2` as a direct child of `release:` in the fixture.

### _orch_load_backend fallback (code issue in scope)
File: `core/orch/contract.sh` lines 193-197
Issue: fallback is `sequential` → triggers misconfigured → stubs remain → all pipeline tests fail
Fix: change to `bash-parallel` (the real default backend)

### keepers-manifest.yaml (4 occurrences — partial fix in build commit 64da51c3)
- Line 2841: done (closed_reason updated in build commit)
- Lines 3329, 3335, 3345: cleanup-delta-d entry (done in same build commit per diff)

### orch-backend-misconfigured-test.sh (3 occurrences)
- Lines 20, 51: comments
- Line 79: test description string

### orch-mock-test.sh (1 occurrence)
- Line 3: sibling-backends comment

## SPEC status (from issue-acceptance stage)
- SPEC-5 (R-5): failing — root cause identified (fixture template scope gap + code issue)
- SPEC-1 (R-1/R-2): code issue in build (fanout.sh subshell boundary, _orch_load_backend fallback)
- SPEC-2 (R-3): test passes negctl
- SPEC-4 (R-4): test passes negctl; installed-tree test not yet present in diff
- SPEC-6 (R-6): test passes negctl; wiring confirmed in local_engine.sh
- SPEC-10 (R-4): test passes negctl
- SPEC-3 (R-3): 3 files still contain orch-sequential (code issue)
- SPEC-7 (R-8): ADR files not yet updated with Enforced by sections

## Status: COMPLETE (revision 12)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md

Key changes: added `tests/fixtures/templates/always-run-minimal.yaml` to scope;
updated SPEC-5 to name the fixture fix; clarified Decision 1 re: `sequential`→`bash-parallel`;
added issue-acceptance findings section.
