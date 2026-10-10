# Open items the run could not settle

The run used its last round with these items still open, and no stage that ran could act on them.

1. **acceptance-gate finding 1** (opened by acceptance-gate): core/pipeline/runner.sh was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none
   - What would settle it: the acceptance-gate check no longer reports it when it runs again: a change that resolves it, or evidence that it is already resolved
   - build: nothing to do — WIRING: none; all SPECs source core/state/run-cap.sh directly; no acceptance test exercises runner.sh; tests/unit/run-cap-test.sh is read-only and no in-scope file can add an integration test for the runner.sh call sites
   - issue-acceptance: nothing to do — the file whose code calls `zbuild_run_cap_admit` is `core/pipeline/runner.sh` (diff lines 2303-2311); no test exercises the wiring through runner.sh (run-cap-test.sh sources run-cap.sh directly), but no stated requirement (R-1 through R-8) mandates an integration test through runner.sh; R-6 requires a regression test that reddened at merge-base, which NEGCTL PASS SPEC-2 confirms at module level.
   - spec-correspondence: nothing to do — this stage judges spec-assertion correspondence only and cannot see or change implementation; identifying which file wires the cap module is outside this stage's scope.
   - test-author: nothing to do — WIRING: none. SPECs 1–6 test `zbuild_run_cap_admit` directly by sourcing the module; no SPEC in this contract covers integration through `runner.sh`. The design's `WIRING: core/pipeline/runner.sh` is an implementation note, not a test obligation.
