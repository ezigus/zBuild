## build — unusable

- changed core/claim/claim.sh, docs/adr/ADR-005-claim-coordinator.md, plugins/claim-coordinator/github-labels/plugin.sh (+7 / -12)

- over 3 pass(es), 3 iteration(s)
- answered: RLPERFORMANCE-1: wrong — the finding no longer holds. The current `core/claim/claim.sh` already uses `jq -r '.acquired | tostring'` for the `acquired` field — no grep-based subshell spawns. This was fixed in commit `0052daee`.
- answered: RLREDTEAM-3: wrong — the unfiltered fallback described in the finding no longer exists in `plugins/claim-coordinator/github-labels/plugin.sh`. The `_ccgl_read_holder` gh-backend path was rewritten in commit `0052daee` to use only the actor-filtered `gh api` call with jq's `select(.user.login == $actor)`; when `body` is empty (no actor, no repo, or no matching comment), the while-loop finds nothing and the function returns empty. There is no `gh issue comment list` fallback. The DSCLA-23 test (38th assertion) confirms the actor-filtering is in place.
- not answered: BUFND-3
- not answered: BUFND-4
- not answered: BUFND-5
- not answered: BUFND-6
- not answered: BUFND-7
- not answered: BUFND-8
- not answered: BUFND-9
- step 1: done — plugins/claim-coordinator/github-labels/plugin.sh | _ccgl_read_holder() {
- step 3: done — scripts/lib/run-status-render.sh | [[ -n "${_ZBUILD_CLAIM_HOLDER:-}" ]] && printf '<!-- zbuild-holder: %s -->\n' "$_ZBUILD_CLAIM_HOLDER"
- step 4: done — core/claim/claim.sh | zbuild_claim_acquire() {
- step 5: done — config/event-schema.json | "pipeline.refused.claimed",
- step 6: done — core/pipeline/runner.sh | eb_emit_event "pipeline.refused.claimed" \
- step 8: done — docs/adr/ADR-059-issue-vs-run-keying.md | - §4 (cross-machine exclusion is the claim coordinator's job; the admission lock handles intra-machine serialisation) →
- refused: step 7 is answered done with no quote: give `QUOTE: <file> | <a line this change added>` (the step: Amend docs/adr/ADR-005-claim-coordinator.md: in the ## Enforced by section, extend the §1 bullet to add: §1(a) enforcement claim-coordinator-unit-test.sh [DSCLA-22] (claim hook called after admission lock and before first stage; release hook called in EXIT path); §1(c) enforcement claim-coordinator-unit-test.sh [DSCLA-3] (refused: non-zero exit, no stage dispatched, event emitted) and claim-coordinator-unit-test.sh [DSCLA-9] (refused output names holder); extend the §2 bullet to name [DSCLA-1] for the "shared label is zbuild:claimed (no hostname)" statement, and [DSCLA-2] and [DSCLA-12] for the holder rendering cases)
- refused: step 2's quote is not a line this change added in plugins/claim-coordinator/github-labels/README.md: Uses a single shared GitHub issue label (`zbuild:claimed`) as the distributed claim mechanism so multiple daemon instances can coordinate over a shared repository without a central lock server. The holder is identified in the run-status comment (`<!-- zbuild-holder: ... -->`), not in the label name. — quote the line you added that does the step, or answer not needed and why (the step: Update plugins/claim-coordinator/github-labels/README.md: remove all references to claimed:<machine>; describe the single shared label zbuild:claimed; update ZBUILD_CLAIM_MACHINE_ID row to note it now affects only the holder string in the run-status comment, not the label name)
