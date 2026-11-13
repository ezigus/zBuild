## intake — pass

- 14 requirement(s): RQRESU-1, RQRESU-2, RQRESU-3, RQFROM-1, RQADR-1, RQADR-2, RQHYDR-1, RQLOOP-1, RQFROM-2, RQFROM-3, RQFROM-4, RQPATH-1, RQGUAR-1, RQGUAR-2

- RQRESU-1: A resume trusts every stage that already ran.
- RQRESU-2: Each stage the interrupted run completed counts as done, and its outputs are put back (rehydrated) exactly as they were when the run stopped.
- RQRESU-3: The run picks up at the stage that was interrupted, which runs again from its start.
- RQFROM-1: `--from-stage <s>` works the same way: every stage before `<s>` is trusted and rehydrated, and the run starts at `<s>`.
- RQADR-1: Amend ADR-006 (resume contract) with the decision above, with the amendment naming its enforcing tests inline.
- RQADR-2: Amend ADR-050 §6 to draw the line explicitly, stating that the rule "never skip a stage on the basis of prior output" governs a **new** run reusing an **earlier run's** work and stays, while resume continues **the same run** and is governed by ADR-006, with a test pinning each side.
- RQHYDR-1: Rehydration follows the same path the hydrate stage already uses (ADR-050, `plugins/tool/hydrate`), so "exactly as before" means the same files at the same paths.
- RQLOOP-1: Inside a loop (e.g. build → test), a run interrupted mid-round resumes at the interrupted stage of that round. The loop's iteration count and state are restored, not reset.
- RQFROM-2: `--from-stage <s>` dispatches `<s>` first, with every earlier stage's outputs rehydrated. It never emits `pipeline.skip_to_stage` and then runs an earlier stage.
- RQFROM-3: `--from-stage <s>` naming a stage with no prior output to rehydrate refuses with a reason, and does not start.
- RQFROM-4: `--from-stage <s>` works only when `--resume` is given. Without `--resume` the run refuses with a reason ("only valid with --resume") and does not start — even when the run would otherwise resume by itself (an automatic resume does not count).
- RQPATH-1: Every way to resume (`--resume`, auto-resume on restart, and `zbuild pipeline resume --run-id`) finds the interrupted run's state in `runs/<run_id>/` and, for a run interrupted during stage *k*, does not dispatch stages 1…*k−1*, keeps their outputs present and byte-identical to what they were at interruption, and dispatches stage *k*. Each has its own test.
- RQGUAR-1: A run with no prior state behaves exactly as today. This is a guard.
- RQGUAR-2: A **new** run of the same issue still never skips a stage because of an earlier run's output (ADR-050 §6). This is a guard.
- the requirements are the same as the last run's
