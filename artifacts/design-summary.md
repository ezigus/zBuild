## design — pass

- 15 SPEC(s): DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-10, DSCLA-11, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8

- DSCLA-1 (covers RQCLA-1, RQLAB-1): When an issue-bound run starts and zbuild:claimed is absent, the label is added before the first stage dispatches
- DSCLA-2 (covers RQCLA-2, RQLAB-2): When a run starts with an issue, the run-status comment identifies the holder; the label name has no hostname
- DSCLA-3 (covers RQCLA-3, RQCLA-9): When a run starts on a claimed issue, it refuses with non-zero exit before any stage
- DSCLA-9 (covers RQCLA-4): When a run is refused because zbuild:claimed is on the issue, the run's output names the holder
- DSCLA-5 (covers RQCLA-5): On normal pipeline completion, zbuild:claimed is removed from the issue
- DSCLA-6 (covers RQCLA-6): On pipeline failure, zbuild:claimed is removed from the issue
- DSCLA-7 (covers RQCLA-7): On TERM signal, zbuild:claimed is removed from the issue
- DSCLA-8 (covers RQCLA-8): A run with no issue number makes no claim and calls no coordinator hook
- DSCLA-10 (covers RQCLA-10): pipeline.refused.claimed is an accepted event name that passes the schema coverage check
- DSCLA-11 (covers RQCLA-5, RQCLA-6, RQCLA-7): The run-status comment shows terminal status when the runner exits on any path
- DSADR-4 (covers RQADR-1): ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path
- DSADR-5 (covers RQADR-2): ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment
- DSADR-6 (covers RQADR-3): ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism
- DSADR-7 (covers RQADR-4): ADR-005 has an ## Enforced by section naming the test or lint that enforces each statement
- DSADR-8 (covers RQADR-5): ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation
- answered: design finding 1: done** — Renamed DSCLA-11 → DSCLA-10 (event-schema coverage SPEC) and DSCLA-12 → DSCLA-11 ([done] run-status SPEC), making them sequential from the DSCLA-9 baseline.
- answered: design finding 2: done** — Added `REMOVED: DSCLA-4 — RQCLA-4 is fully covered by DSCLA-9, which tests the observable runner output; keeping a separate assertion that _ZBUILD_CLAIM_HOLDER is internally set tests the same interaction path with no additional observable coverage`.
- answered: design finding 3: done** — Replaced the DSCLA-8 `Then:` clause. It now reads `Then: zbuild_claim_acquire returns 0` and `And: no gh label command is invoked` — both are observable from a mocked `gh`.
- not answered: test-author finding 1
