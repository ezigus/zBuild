## intake — pass

- took in the goal for issue #1805: [bug] --resume and --from-stage trust and rehydrate every st

- goal length: 4989 chars
- platforms: 1
- the requirements changed since the last run:
  - added: RESU-1 A resume trusts every stage that already ran.
  - added: RESU-2 Each stage the interrupted run completed counts as done, and its outputs are put back (rehydrated) exactly as they were when the run stopped.
  - added: RESU-3 The run picks up at the stage that was interrupted, which runs again from its start.
  - added: FROM-1 `--from-stage <s>` works the same way: every stage before `<s>` is trusted and rehydrated, and the run starts at `<s>`.
  - added: RESU-4 A run is interrupted during stage *k*. Resuming it does not dispatch stages 1…*k−1*, their outputs are present and byte-identical to what they were at the interruption, and stage *k* is dispatched.
  - added: LOOP-1 Inside a loop (e.g. build → test), a run interrupted mid-round resumes at the interrupted stage of that round. The loop's iteration count and state are restored, not reset.
  - added: FROM-2 `--from-stage <s>` dispatches `<s>` first, with every earlier stage's outputs rehydrated. It never emits `pipeline.skip_to_stage` and then runs an earlier stage.
  - added: FROM-3 `--from-stage <s>` naming a stage with no prior output to rehydrate refuses with a reason, and does not start.
  - added: PATH-1 Every way to resume (`--resume`, auto-resume on restart, and `zbuild pipeline resume --run-id`) finds the interrupted run's state in `runs/<run_id>/` and behaves as R1. Each has its own test.
  - added: GUAR-1 A run with no prior state behaves exactly as today.
  - added: GUAR-2 A **new** run of the same issue still never skips a stage because of an earlier run's output (ADR-050 §6).
  - added: ADR-1 Amend ADR-006 (resume contract) with the decision above, with the amendment naming its enforcing tests inline.
  - added: ADR-2 Amend ADR-050 §6 to draw the line explicitly, stating that the rule "never skip a stage on the basis of prior output" governs a **new** run reusing an **earlier run's** work and stays, while resume continues **the same run** and is governed by ADR-006, with a test pinning each side.
  - added: HYDR-1 Rehydration follows the same path the hydrate stage already uses (ADR-050, `plugins/tool/hydrate`), so "exactly as before" means the same files at the same paths.
  - added: TEST-1 Tests for R1–R5 must use a cycle.
  - added: ORDE-1 Do not run this in parallel with another issue that edits the dispatch loop.
