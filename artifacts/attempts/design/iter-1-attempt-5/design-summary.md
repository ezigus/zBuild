## design — fail

- the design fails 3 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done** — DSCLA-12 evidence is now on the same line as the SPEC: `DSCLA-12[done]: ... evidence: scripts/lib/run-status-render.sh | rsc_finalize_body() {`. Removed the separate indented evidence line.
- answered: design finding 2: done** — The design no longer creates `core/claim/claim.sh` as a new owner. The first step now amends `plugins/claim-coordinator/github-labels/plugin.sh` to change `claim_coordinator_claim` and `claim_coordinator_release` to implement the new behavior (zbuild:claimed label, holder extraction). `core/claim/claim.sh` is now a thin wiring bridge that sources the plugin and delegates to its public functions — no private `_ccgl_*` calls.
- answered: design finding 3: done** — DSCLA-1 When changed from "zbuild_claim_acquire is called with the issue number before worktree entry" to "the run starts".
- answered: design finding 4: done** — DSCLA-2 Given changed from "zbuild_claim_acquire succeeds for the issue" to "a run starts with an issue number". When changed from "the run-status comment is examined" to "the run-status comment is first posted to the issue".
- answered: design finding 5: done** — DSCLA-3 When changed from "zbuild_claim_acquire is called" to "a run is started on that issue".
- answered: design finding 6: done** — DSCLA-4 is dropped (it only appeared in rejected designs; no REMOVED line needed). RQCLA-4 is covered by DSCLA-9. The duplicate-action problem is resolved by removing DSCLA-4 entirely.
- answered: design finding 7: done** — DSCLA-5 When changed from "_runner_abort_trap fires with _runner_ended=true" to "the pipeline completes normally".
- answered: design finding 8: done** — DSCLA-6 When changed from "_runner_abort_trap fires with failure exit" to "the pipeline exits due to a stage failure".
- answered: design finding 9: done** — DSCLA-7 When changed from "the runner process receives SIGTERM (_runner_signal_trap then _runner_abort_trap)" to "the runner process receives SIGTERM".
- answered: design finding 10: done** — DSCLA-8 When changed from "zbuild_claim_acquire is called with an empty issue argument" to "the run starts". Given changed from "the run is started with --goal and no --issue (issue number is empty)" to "the run is started with --goal and no --issue".
- answered: design finding 11: done** — DSCLA-11 Given changed from "pipeline.refused.claimed is emitted in runner.sh when zbuild:claimed is present" to "zbuild:claimed is on the issue". When changed from "the event-schema emitted coverage check runs" to "the run is refused and emits pipeline.refused.claimed".
- answered: test-author finding 1: not mine** — The exit-12 failure before DSCLA-1 ran is a test-file organisation issue: DSCLA-9 integration-level assertions run before DSCLA-1 unit-level assertions in the same file, and failing early stops the file. The SPEC descriptions are correct; the test separation decision belongs to the test author.
