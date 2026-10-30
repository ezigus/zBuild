# Design: #1753 — Fix unfinished review lens treated as pass

## Architectural Decision Summary

**Goal.** A review lens that does not finish must count as a failure: `ZBUILD_RUN_FLAGGED=yes` is set
and the pipeline stops before any further stage runs, so no PR is opened and nothing merges unless
every lens finishes and passes.

**Context.** Two separate gaps existed:

1. `_map_write_summary` in `core/pipeline/strategies/map.sh` set `ZBUILD_RUN_FLAGGED=yes` only when
   `outcome == fail` (line 157). Unfinished outcomes (`timed_out`, `out_of_turns`, `interrupted`,
   `broken`, `missing`, etc.) left `flagged=no`, so delivery proceeded to merge as if the lens had
   passed.

2. Even after setting `ZBUILD_RUN_FLAGGED=yes`, runner.sh had no guard to stop the run: later stages
   (pr_open, pr-delivery, merge) could still be dispatched. R-1 requires "the run stops" — not merely
   that delivery blocks at its own gate.

**Decision.**

*map.sh (already implemented):* Change line 157 from:
```bash
[[ "$outcome" == fail ]] && flagged=yes
```
to:
```bash
[[ "$outcome" != pass ]] && flagged=yes
```
Any outcome that is not `pass` — conclusive `fail` or any unfinished outcome — sets
`ZBUILD_RUN_FLAGGED=yes`.

*runner.sh (already implemented):* After `_strategy_run_map` returns, a new guard at line 3731 checks
`ZBUILD_RUN_FLAGGED=yes`. If set, it writes `pipeline_status=failed`, sets the group's verdict to
`failed`, emits `pipeline.end`, and returns 1 — stopping the run before `_update_stage_status` is
reached. No further stage is dispatched.

The previous design claimed runner.sh needed no code change because delivery-level blocking existed.
That was wrong: "the run stops" (R-1) means the pipeline returns before the next stage; blocking
inside pr-delivery is insufficient. The implementation correctly added the stop block.

*Correction on SPEC-8 regression:* The runner.sh stop block inserts ~14 lines at arm-position ~109
(before `_update_stage_status` at arm-position ~121). The existing `runner-map-parallel-stage-envelope-test.sh`
extracts the map arm with `awk … count>=115`, which now falls 6 lines short of `_update_stage_status`.
SPEC-8 gives a false negative. The awk window must be widened to ≥128 — which also enables SPEC-4's
new assertion over the full arm.

*ADR-040 amendment (§2368 part 2):* The existing `Enforced by` names only `engine-combines-map-test.sh`
SPEC-1 for flag-setting. The amended statement now also covers "runner.sh stops the run" — the ADR
text must add this sentence and its `Enforced by` must name SPEC-4's test.

```scope
core/pipeline/strategies/map.sh
core/pipeline/runner.sh
docs/adr/ADR-040-composable-gate-lens-taxonomy.md
tests/unit/engine-combines-map-test.sh
tests/unit/runner-map-parallel-stage-envelope-test.sh
tests/integration/map-members-reported-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
tests/unit/merge-v2-result-test.sh
tests/unit/pr-delivery-v2-result-test.sh
tests/unit/pr-open-v2-inputs-test.sh
tests/unit/pr-open-v2-result-test.sh
plugins/agent/pr-delivery/plugin.sh
plugins/tool/merge/plugin.sh
plugins/tool/pr-open/tests/pr-open-test.sh
```

```acceptance
SPEC-1[code]: When any map member's outcome is not `pass`, `_strategy_run_map` exports `ZBUILD_RUN_FLAGGED=yes`. covers: R-1
SPEC-2[no-code]: ADR-040 §2368 part 2 is amended to add that when `ZBUILD_RUN_FLAGGED=yes` runner.sh stops the run at the map dispatch arm before dispatching further stages, and its `Enforced by` entry names both SPEC-1 (flag-setting) and SPEC-4 (run-stops) tests. covers: R-1
SPEC-3[done]: Under `auto_unless_flagged`, pr-delivery routes to pr-open (not merge) when `ZBUILD_RUN_FLAGGED=yes`. covers: R-1 evidence: plugins/agent/pr-delivery/plugin.sh:161 tests/integration/merge-policy-auto-unless-flagged-test.sh
SPEC-4[code]: When `ZBUILD_RUN_FLAGGED=yes` after `_strategy_run_map`, runner.sh's map dispatch arm returns 1 before calling `_update_stage_status` for the group. covers: R-1
WIRING: core/pipeline/runner.sh
TESTFILES:
SPEC-1: tests/unit/engine-combines-map-test.sh
SPEC-4: tests/unit/runner-map-parallel-stage-envelope-test.sh
```

```supersedes
tests/unit/runner-map-parallel-stage-envelope-test.sh [SPEC-8]: the awk extraction window (count>=115) no longer captures `_update_stage_status` — the stop block (#1753) inserts ~14 lines before it, pushing it to arm-position ~121; widen the count to >=128 so both SPEC-8 and the new SPEC-4 assertion cover the full arm
```

## Findings

**Finding: previous design claimed runner.sh needs no code change — wrong.**
The design said "Runner.sh does not condition on `_ZB_MAP_UNFINISHED` for run-stopping; no code
changes are needed." This was incorrect. R-1 requires "the run stops" — `ZBUILD_RUN_FLAGGED=yes`
alone does not stop the run; it is only a signal to downstream consumers. The implementation
correctly added the stop block (lines 3728–3742). The design now reflects this.

**Finding: SPEC-8 regression.**
The awk window (115 lines) in `runner-map-parallel-stage-envelope-test.sh` no longer captures
`_update_stage_status` because the stop block was inserted before it. SPEC-8 gives a false
negative — the behavior (success path writes stage_statuses) is unchanged; the test implementation
is broken. Added to supersedes; the implementer widens the count to ≥128.

**Finding: SPEC-4 test absent, WIRING check failed.**
The acceptance checker reverted `runner.sh` and all tests still passed, so the stop block was
untested. SPEC-4 is a new [code] requirement. Its test in `runner-map-parallel-stage-envelope-test.sh`
(consistent with that file's code-presence approach) greps the map arm for the `ZBUILD_RUN_FLAGGED`
guard. Reverting runner.sh removes the guard → SPEC-4 fails → WIRING check passes.

**Finding: SPEC-2 Enforced by incomplete.**
The ADR's `Enforced by` named only `engine-combines-map-test.sh` SPEC-1, which covers flag-setting
but not run-stopping. SPEC-2[no-code] is updated to require the ADR to also add the run-stops
sentence and name SPEC-4's test file in `Enforced by`.

**Plan scope items not requiring code changes.**
`plugins/agent/pr-delivery/plugin.sh`, `plugins/tool/merge/plugin.sh`, and several pr-open tests
are in scope for verification only — their behavior is unchanged. The pr-delivery gate (`plugin.sh:161`)
and merge guard already handle `ZBUILD_RUN_FLAGGED=yes` correctly; this remains [done] as SPEC-3.

**`map-members-reported-test.sh` and other integration tests.**
These are in scope for regression verification. No new assertions are required there; SPEC-1 and
SPEC-4 cover the code paths they would exercise.
