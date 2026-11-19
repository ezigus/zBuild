## design — pass

- 21 SPEC(s): DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8, DSCLA-14

- DSCLA-1 (covers RQCLA-1, RQLAB-1, RQLAB-2): When an issue-bound run starts and zbuild:claimed is absent, the label is added before the first stage dispatches
- DSCLA-2 (covers RQCLA-2): When a local run starts with an issue, rsc_render_header embeds the holder in the run-status comment header
- DSCLA-12 (covers RQCLA-2): When a CI run starts with an issue, the rendered run-status comment header contains the CI run URL as the holder
- DSCLA-3 (covers RQCLA-3, RQCLA-9): When a run starts on a claimed issue, it refuses with non-zero exit before any stage
- DSCLA-9 (covers RQCLA-4): When a run is refused because zbuild:claimed is on the issue, the run's output names the holder
- DSCLA-5 (covers RQCLA-5): On normal pipeline completion, zbuild:claimed is removed from the issue
- DSCLA-6 (covers RQCLA-6): On pipeline failure, zbuild:claimed is removed from the issue
- DSCLA-7 (covers RQCLA-7): On TERM signal, zbuild:claimed is removed from the issue
- DSCLA-8 (covers RQCLA-8): When zbuild_claim_acquire is called with an empty issue argument, it returns 0 and invokes no gh label command
- DSCLA-17 (covers RQCLA-8): When zbuild_claim_release is called without a prior successful acquire, it invokes no gh label command
- DSCLA-10 (covers RQCLA-10): When the event-schema emitted-coverage check runs, it accepts pipeline.refused.claimed as a registered event
- DSCLA-11 (covers RQCLA-5, RQCLA-6, RQCLA-7): The run-status comment shows terminal status when the runner exits on any path
- DSCLA-15 (covers RQCLA-4): The holder string is printed without interpreting escape sequences in the run's refusal output
- DSCLA-16 (covers RQCLA-6): When claim acquisition succeeds but runner infrastructure setup fails before the EXIT trap is installed, zbuild:claimed is removed before the runner function returns
- DSCLA-13 (covers RQCLA-11): When a second SIGTERM arrives during the runner's claim release, zbuild:claimed is still removed
- DSADR-4 (covers RQADR-1): ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path
- DSADR-5 (covers RQADR-2): ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment
- DSADR-6 (covers RQADR-3): ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism
- DSADR-7 (covers RQADR-4): ADR-005 has an ## Enforced by section with the §1 bullet extended to include §1(c)'s tests (claim-coordinator-unit-test.sh [DSCLA-3]: refused — non-zero exit, no stage, event emitted; teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder), and the §2 bullet extended to include [DSCLA-12] for the CI holder rendering case
- DSADR-8 (covers RQADR-5): ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation; the amendment's Enforced by entry names DSCLA-3 as the test that enforces the cross-machine exclusion statement
- DSCLA-14 (covers RQDOC-1): README.md in plugins/claim-coordinator/github-labels/ tells the reader the shared claim label is zbuild:claimed (not claimed:<machine>) and does not reference machine-suffixed labels
- answered: design finding 1: done — Added DSCLA-17[code] covering RQCLA-8's release side: `Given: core/claim/claim.sh is loaded; _ZBUILD_CLAIM_ACQUIRED is not set / When: zbuild_claim_release is called / Then: no gh label command is invoked`. DSCLA-8 covers the acquire no-op; DSCLA-17 covers the release no-op.
- answered: design finding 2: done — Restored DSCLA-10's `When:` to `When: the event-schema emitted-coverage check runs against the codebase`. The previous round changed it to `When: config/event-schema.json is read` to match the test-author's direct-grep implementation, but that describes a test technique, not a software action. The SPEC is authoritative; the test-author must invoke the coverage check to satisfy it.
- not answered: test-author finding 1
- not answered: test-author finding 2
