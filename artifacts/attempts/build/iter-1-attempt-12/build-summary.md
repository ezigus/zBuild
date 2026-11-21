## build — pass

- changed core/claim/claim.sh, plugins/claim-coordinator/github-labels/plugin.sh (+26 / -19)

- over 2 pass(es), 2 iteration(s)
- answered: BUFND-1: done — the race-condition path in `claim_coordinator_claim` was added by this change. The representative line is `    _ccgl_add_label "$issue" "zbuild:claimed" || add_rc=$?` in `plugins/claim-coordinator/github-labels/plugin.sh`, added in this branch's latest commit. When `_ccgl_add_label` exits 2 (label already present inside the flock), `add_rc` captures it and triggers the `{"acquired": false, "holder": "..."}` return — fulfilling step 1's "returns conflict JSON" requirement for the race path.
- answered: acceptance-gate-code finding 1: not mine — the finding requires adding a test that asserts `core/claim/claim.sh` is in `config/shape-change-paths.txt`. Adding a test requires editing a test file; test files are off-limits for this stage. The entry is already in the file (line 13 of `config/shape-change-paths.txt`). The test-author stage must add the assertion.
- answered: lens-sre-code finding 1: not mine — the DSCLA-9 fixture is hand-written inside `tests/integration/teardown-repeat-signal-test.sh`, which is a test file this stage cannot change. The fix (generating the fixture via `rsc_render_header`) belongs to the test-author stage.
- step 1: done — plugins/claim-coordinator/github-labels/plugin.sh | _ccgl_add_label "$issue" "zbuild:claimed" || add_rc=$?
- step 2: not needed — plugins/claim-coordinator/github-labels/README.md already describes zbuild:claimed with no claimed:<machine> references and notes that ZBUILD_CLAIM_MACHINE_ID affects only the holder string in the run-status comment.
- step 3: not needed — scripts/lib/run-status-render.sh already emits <!-- zbuild-holder: CI_URL --> and <!-- zbuild-holder: run_id=X machine=H --> in rsc_render_header; added in earlier iterations.
- step 4: not needed — core/claim/claim.sh exists as the wiring bridge: sources registry.sh, implements zbuild_claim_build_holder, zbuild_claim_acquire, zbuild_claim_release with all specified guards.
- step 5: not needed — config/event-schema.json already registers pipeline.refused.claimed following the pattern of pipeline.refused.issue_locked.
- step 6: not needed — core/pipeline/runner.sh already has all claim wiring: sources claim.sh (line 33), calls zbuild_claim_build_holder, zbuild_claim_acquire, emits event + printf '%s\n' on refusal, calls zbuild_claim_release in runner_abort_trap, and adds zbuild_claim_release true on early-failure paths.
- step 7: not needed — docs/adr/ADR-005-claim-coordinator.md already has the ## Enforced by section with §1 bullets naming [DSCLA-22], [DSCLA-3], [DSCLA-9] and §2 bullet naming [DSCLA-1], [DSCLA-2], [DSCLA-12].
- step 8: not needed — docs/adr/ADR-059-issue-vs-run-keying.md already has the §4 Enforced by entry naming [DSCLA-3].
