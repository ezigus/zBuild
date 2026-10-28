# Design notes — issue #1801 (revision 13)

## What changed from revision 12

### Issue-acceptance findings addressed in revision 13

**Finding 1/2 (R-4): installed-tree end-to-end test absent**
`orch-backend-misconfigured-test.sh` only calls `orch_load_backend` in isolation (sourcing
contract.sh from checkout). The issue requires the full pipeline run to fail as `misconfigured`.

SPEC-4 and SPEC-10 updated to require two layers:
- (a) unit: existing `orch_load_backend` call returning non-zero (already in test)
- (b) end-to-end: create minimal installed tree (rsync core/plugins/config/scripts to temp dir),
  run `bash $ZBUILD_HOME/core/pipeline/runner.sh` end-to-end, assert pipeline exits non-zero
  with `misconfigured`

runner.sh code change needed (in scope): check `_ZBUILD_ORCH_BACKEND_DISPOSITION` immediately
after sourcing `contract.sh`; fail pipeline before any stage dispatch when `misconfigured`.

**Finding 3 (R-5): persist hook never entered**
`always-run-exit-paths-test.sh` exits in 0s without dispatching persist. Root cause: `extends:`
does not propagate `always_run:` from the extending template. Only base template's `[release]`
ends up in `_TPL_ALWAYS_RUN`.

SPEC-5 updated: template extension must propagate `always_run:` from extending template.
Scope additions: `core/pipeline/template.sh` and `core/pipeline/template-resolver.sh`
(these were absent but contain the code building `_TPL_ALWAYS_RUN`).

**Finding 4 (R-5): `[SPEC-5]` release cleanup regression**
negctl confirms `[SPEC-5]` cleanup FAILS at BOTH baseline AND HEAD. It was failing at baseline
with old code (router.timeout_s=30s watchdog, 15s kill grace too short). At HEAD the 3s
watchdog should allow teardown within the 15s kill grace — but it STILL fails. Root cause is in
the hard-kill abort-trap dispatch path. Build stage must fix.

**Finding 5 (R-9)**: Follows from findings 3 and 4 (2 failing tests remain).

**Finding 6 (R-7 confirmed)**: Ran all five greps at HEAD. 22 total matching files. All files
pinning always-run watchdog behavior are in scope. Files matching `router.timeout_s` for the
per-call model timeout are not in scope. Documented in issue-acceptance findings section.

## Key invariants for build stage

1. runner.sh must check `_ZBUILD_ORCH_BACKEND_DISPOSITION` at startup (after sourcing
   contract.sh), before any stage is dispatched, and fail the pipeline as `misconfigured`.

2. Template extension (`extends:`) must propagate `always_run:` from the extending template
   (extending template wins over base, consistent with all other field overrides).

3. Hard-kill path: `_runner_abort_trap` → `_runner_dispatch_always_run` must complete before
   the kill grace expires. With `_SPEC5_KILL_GRACE=15` s and a 3 s watchdog, there is 12 s
   slack — this should be achievable if the abort trap is correctly wired to the EXIT trap.

4. negctl must show `[SPEC-5]` cleanup FAILING at baseline and PASSING at HEAD.

## Scope additions in revision 13

```
core/pipeline/template.sh
core/pipeline/template-resolver.sh
```

## Status: COMPLETE (revision 13)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md

Key changes from revision 12:
- SPEC-4 and SPEC-10: added end-to-end installed-tree test requirement
- SPEC-5: added template extension propagation requirement; added template.sh/template-resolver.sh to scope
- issue-acceptance findings section added (revision 13)
- R-7 scope discovery results documented explicitly
