## build — pass

- changed no file

- over 1 pass(es), 1 iteration(s)
- answered: BUFND-3: wrong — step 1 is answered correctly in this build output: `plugins/claim-coordinator/github-labels/plugin.sh | _ccgl_read_holder() {`; the finding was raised in attempt-15 when I had no step answer; the step is accepted in the current build
- answered: BUFND-4: wrong — step 2 is not needed: README.md correctly describes `zbuild:claimed` as the single shared label with no `claimed:<machine>` references; `ZBUILD_CLAIM_MACHINE_ID` row notes it affects only the holder string in the run-status comment; done in a prior commit before the current iteration
- answered: BUFND-5: wrong — step 3 is answered correctly in this build output: `scripts/lib/run-status-render.sh | [[ -n "${_ZBUILD_CLAIM_HOLDER:-}" ]] && printf '<!-- zbuild-holder: %s -->\n' "$_ZBUILD_CLAIM_HOLDER"`; finding was from attempt-15 with no step answer
- answered: BUFND-6: wrong — step 4 is answered correctly in this build output: `core/claim/claim.sh | zbuild_claim_acquire() {`; finding was from attempt-15
- answered: BUFND-7: wrong — step 5 is answered correctly in this build output: `config/event-schema.json | "pipeline.refused.claimed",`; finding was from attempt-15
- answered: BUFND-8: wrong — step 6 is answered correctly in this build output: `core/pipeline/runner.sh | eb_emit_event "pipeline.refused.claimed" \`; finding was from attempt-15
- answered: BUFND-9: wrong — step 8 is answered correctly in this build output: `docs/adr/ADR-059-issue-vs-run-keying.md | - §4 (cross-machine exclusion is the claim coordinator's job; the admission lock handles intra-machine serialisation) →`; finding was from attempt-15
- answered: BUFND-10: wrong — the step IS done; commit 12e9cf5e added `§1(b) enforcement` to ADR-005 ## Enforced by; my previous response had no QUOTE line. The quote is: `docs/adr/ADR-005-claim-coordinator.md | §1(b) enforcement \`plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh\``
- answered: BUFND-11: wrong — step 2 is not needed: `plugins/claim-coordinator/github-labels/README.md` already describes `zbuild:claimed` as the single shared label (no machine suffix), explains the holder is in the run-status comment, and notes ZBUILD_CLAIM_MACHINE_ID affects only the holder string; this was done in commit 236cf897 prior to the current iteration; there is no line from `git diff HEAD` to quote because README.md was not changed in the current iteration
- answered: RLPERFORMANCE-1: wrong — not reproduced: `core/claim/claim.sh` uses `jq -r '.acquired | tostring'` for the acquired field; fixed in commit `0052daee`
- answered: RLREDTEAM-3: wrong — not reproduced: `_ccgl_read_holder` in `plugins/claim-coordinator/github-labels/plugin.sh` uses only the actor-filtered `gh api` call; the unfiltered fallback was removed in commit `0052daee`; when `body` is empty the function returns empty with no fallback
- step 1: done — plugins/claim-coordinator/github-labels/plugin.sh | _ccgl_read_holder() {
- step 3: done — scripts/lib/run-status-render.sh | [[ -n "${_ZBUILD_CLAIM_HOLDER:-}" ]] && printf '<!-- zbuild-holder: %s -->\n' "$_ZBUILD_CLAIM_HOLDER"
- step 4: done — core/claim/claim.sh | zbuild_claim_acquire() {
- step 5: done — config/event-schema.json | "pipeline.refused.claimed",
- step 6: done — core/pipeline/runner.sh | eb_emit_event "pipeline.refused.claimed" \
- step 7: done — docs/adr/ADR-005-claim-coordinator.md | §1(b) enforcement `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
- step 8: done — docs/adr/ADR-059-issue-vs-run-keying.md | - §4 (cross-machine exclusion is the claim coordinator's job; the admission lock handles intra-machine serialisation) →
- step 2: not needed — plugins/claim-coordinator/github-labels/README.md already describes zbuild:claimed as the single shared label with no claimed:<machine> references; the ZBUILD_CLAIM_MACHINE_ID row says "affects the holder string in the run-status comment only, not the label name"; done in commit 236cf897 (prior iteration); README.md was not touched in the current iteration's diff
