## intake — pass

- 10 requirement(s): RQCLA-1, RQCLA-2, RQCLA-3, RQCLA-4, RQCLA-5, RQCLA-6, RQCLA-7, RQCLA-8, RQLAB-1, RQLAB-2; 2 limit(s): RQMECH-1, RQMECH-2

- RQCLA-1: When the issue has no `zbuild:claimed` label, the run adds it before the first stage dispatches
- RQCLA-2: When the label is added, the run's progress comment names the holder: run id and machine, or CI run URL
- RQCLA-3: When the `zbuild:claimed` label is present, the run refuses to start with non-zero exit and no stage dispatched
- RQCLA-4: When refusing to start, the run's message names the holder from the holder's progress comment
- RQCLA-5: On normal end, the label is removed and the progress comment is marked finished
- RQCLA-6: On failure, the label is removed and the progress comment is marked finished
- RQCLA-7: On interrupt (TERM), the label is removed and the progress comment is marked finished
- RQCLA-8: A run with no issue (goal only) makes no claim
- RQLAB-1: A local run and a CI run use the same label
- RQLAB-2: The label has no hostname in it
- RQMECH-1: Do not build a check of a CI job's status through the GitHub Actions API (limit)
- RQMECH-2: Do not build a "do I still hold the claim" check before each stage (limit)
