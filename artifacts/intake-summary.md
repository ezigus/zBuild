## intake — pass

- 17 requirement(s): RQCLA-1, RQCLA-2, RQCLA-3, RQCLA-4, RQCLA-5, RQCLA-6, RQCLA-7, RQCLA-8, RQCLA-9, RQCLA-10, RQLAB-1, RQLAB-2, RQADR-1, RQADR-2, RQADR-3, RQADR-4, RQADR-5; 2 limit(s): RQMECH-1, RQMECH-2

- RQCLA-1: When the issue has no `zbuild:claimed` label, the run adds it before the first stage dispatches
- RQCLA-2: When the label is added, the run's progress comment names the holder: run id and machine, or CI run URL
- RQCLA-3: When the `zbuild:claimed` label is present, the run refuses to start with non-zero exit and no stage dispatched
- RQCLA-4: When refusing to start, the run's message names the holder from the holder's progress comment
- RQCLA-5: On normal end, the label is removed and the progress comment is marked finished
- RQCLA-6: On failure, the label is removed and the progress comment is marked finished
- RQCLA-7: On interrupt (TERM), the label is removed and the progress comment is marked finished
- RQCLA-8: A run with no issue (goal only) makes no claim and calls no coordinator hook
- RQCLA-9: When the `zbuild:claimed` label is present, the run emits the `pipeline.refused.claimed` event
- RQCLA-10: The `pipeline.refused.claimed` event is registered in `config/event-schema.json`
- RQLAB-1: A local run and a CI run use the same label
- RQLAB-2: The label has no hostname in it
- RQADR-1: Amend ADR-005 (claim coordinator) with: the engine calls the coordinator `claim` after the admission lock and before the first stage, and `release` in the EXIT path
- RQADR-2: Amend ADR-005 with: the single shared label, and that the holder is in the run-status comment
- RQADR-3: Amend ADR-005 to correct the stale parts: selection is not from `config/zbuild.yaml`, and "the engine has no built-in mechanism" no longer holds once the engine calls the coordinator
- RQADR-4: The ADR-005 amendments must include an `## Enforced by` section naming the tests that enforce each statement
- RQADR-5: Amend ADR-059 §4 to note that cross-machine exclusion is the claim coordinator's job, and the admission lock stays for one machine
- RQMECH-1: Do not build a check of a CI job's status through the GitHub Actions API (limit)
- RQMECH-2: Do not build a "do I still hold the claim" check before each stage (limit)
- the issue is unchanged since the last run: its requirements were kept, with no model call
