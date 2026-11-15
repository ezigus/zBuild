## design — pass

- 9 SPEC(s): DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-4, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8

- DSCLA-1 (covers RQCLA-1, RQLAB-1): When an issue-bound run starts and zbuild:claimed is absent, the label is added to the issue before the first stage dispatches
- DSCLA-2 (covers RQCLA-2, RQLAB-2): When the claim is acquired, the claim comment on the issue names the holder; the label name contains no hostname
- DSCLA-3 (covers RQCLA-3): When zbuild:claimed is on the issue, the run exits non-zero without dispatching any stage
- DSCLA-4 (covers RQCLA-4): When zbuild_claim_acquire returns 1, _ZBUILD_CLAIM_HOLDER is set from the holder's claim comment
- DSCLA-9 (covers RQCLA-4): When refusing to start, the runner's output message contains the holder string from the claim comment
- DSCLA-5 (covers RQCLA-5): On normal pipeline completion, zbuild:claimed is removed and the claim comment is updated to finished
- DSCLA-6 (covers RQCLA-6): On pipeline failure, zbuild:claimed is removed and the claim comment is updated to finished
- DSCLA-7 (covers RQCLA-7): On TERM signal, zbuild:claimed is removed and the claim comment is updated to finished
- DSCLA-8 (covers RQCLA-8): A run with no issue number does not check or modify zbuild:claimed
- answered: design finding 1: done — Rewrote DSCLA-9's `When:` from "runner.sh processes the return value and exits without dispatching stages" (internal mechanism) to "the runner is started on that issue" (the observable triggering action). Also updated the `Given:` from internal variable state (`zbuild_claim_acquire returns 1 and _ZBUILD_CLAIM_HOLDER is set`) to the observable pre-condition (`zbuild:claimed is on the issue and a claim comment with a holder string exists`), so both clauses now describe what a test can observe rather than how the code implements it.
