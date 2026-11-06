## intake — pass

- 16 requirement(s): RESU-1, RESU-2, RESU-3, FROM-1, RESU-4, LOOP-1, FROM-2, FROM-3, PATH-1, GUAR-1, GUAR-2, ADR-1, ADR-2, HYDR-1, TEST-1, DISP-1

- RESU-1: A resume trusts every stage that already ran.
- RESU-2: Each stage the interrupted run completed counts as done, and its outputs are put back (rehydrated) exactly as they were when the run stopped.
- RESU-3: The run picks up at the stage that was interrupted, which runs again from its start.
- FROM-1: `--from-stage <s>` works the same way: every stage before `<s>` is trusted and rehydrated, and the run starts at `<s>`.
- RESU-4: A run is interrupted during stage *k*. Resuming it does not dispatch stages 1…*k−1*, their outputs are present and byte-identical to what they were at the interruption, and stage *k* is dispatched.
- LOOP-1: Inside a loop (e.g. build → test), a run interrupted mid-round resumes at the interrupted stage of that round. The loop's iteration count and state are restored, not reset.
- FROM-2: `--from-stage <s>` dispatches `<s>` first, with every earlier stage's outputs rehydrated. It never emits `pipeline.skip_to_stage` and then runs an earlier stage.
- FROM-3: `--from-stage <s>` naming a stage with no prior output to rehydrate refuses with a reason, and does not start.
- PATH-1: Every way to resume (`--resume`, auto-resume on restart, and `zbuild pipeline resume --run-id`) finds the interrupted run's state in `runs/<run_id>/` and behaves as R1. Each has its own test.
- GUAR-1: A run with no prior state behaves exactly as today. This is a guard.
- GUAR-2: A **new** run of the same issue still never skips a stage because of an earlier run's output (ADR-050 §6). This is a guard.
- ADR-1: Amend ADR-006 (resume contract) with the decision above, with the amendment naming its enforcing tests inline.
- ADR-2: Amend ADR-050 §6 to draw the line explicitly, stating that the rule "never skip a stage on the basis of prior output" governs a **new** run reusing an **earlier run's** work and stays, while resume continues **the same run** and is governed by ADR-006, with a test pinning each side.
- HYDR-1: Rehydration follows the same path the hydrate stage already uses (ADR-050, `plugins/tool/hydrate`), so "exactly as before" means the same files at the same paths.
- TEST-1: Tests for R1–R5 must use a cycle.
- DISP-1: No requirement may be marked done, and no change made, on the strength of the legacy loop.
- the requirements are the same as the last run's
