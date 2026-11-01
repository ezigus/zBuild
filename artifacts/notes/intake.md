# Issue #1805 Intake — Requirements

## Summary
This intake extracts requirements from issue #1805 (resume and --from-stage contract). The issue specifies a decision on trust and rehydration, behavioral acceptance criteria (R1-R7), and ADR amendments. The issue provides explicit requirements in three sections: Decision, ADR amendments, and Required behavior (R1-R7).

## Requirements

REQUIREMENT: A resume trusts every stage that already ran.

REQUIREMENT: Each stage the interrupted run completed counts as done, and its outputs are put back (rehydrated) exactly as they were when the run stopped.

REQUIREMENT: The run picks up at the stage that was interrupted, which runs again from its start.

REQUIREMENT: --from-stage <s> works the same way: every stage before <s> is trusted and rehydrated, and the run starts at <s>.

REQUIREMENT: Amend ADR-006 (resume contract) with the decision that a resume trusts every stage that already ran, with the amendment naming its enforcing tests inline.

REQUIREMENT: Amend ADR-050 §6 to draw the line explicitly between resume (continues the same run, governed by ADR-006) and new-run reuse (earlier run's work, governed by ADR-050 §6).

REQUIREMENT: Rehydration must follow the same path the hydrate stage already uses (ADR-050, plugins/tool/hydrate), so "exactly as before" means the same files at the same paths.

REQUIREMENT: A run interrupted during stage k must not dispatch stages 1…k−1; their outputs must be present and byte-identical to what they were at the interruption; and stage k must be dispatched. (R1)

REQUIREMENT: Inside a loop (e.g. build → test), a run interrupted mid-round must resume at the interrupted stage of that round, with the loop's iteration count and state restored, not reset. (R2)

REQUIREMENT: --from-stage <s> must dispatch <s> first, with every earlier stage's outputs rehydrated, and must never emit pipeline.skip_to_stage and then run an earlier stage. (R3)

REQUIREMENT: --from-stage <s> naming a stage with no prior output to rehydrate must refuse with a reason and must not start. (R4)

REQUIREMENT: Every way to resume (--resume, auto-resume on restart, and zbuild pipeline resume --run-id) must find the interrupted run's state in runs/<run_id>/ and behave as R1, with each having its own test. (R5)

REQUIREMENT: A run with no prior state must behave exactly as today. (R6 — guard clause)

REQUIREMENT: A new run of the same issue must still never skip a stage because of an earlier run's output (ADR-050 §6). (R7 — guard clause)

## Notes

- The issue provides a Decision section that establishes trust and rehydration semantics.
- Three explicit bugs are documented in "What is wrong today": the live dispatch loop doesn't read resume state; --from-stage doesn't act; auto-resume reads from the wrong state location. Fixing these bugs is required to meet R1–R5.
- The issue explicitly names R1–R7 under "Required behavior" as acceptance criteria. R6 and R7 are guard clauses to ensure existing behavior is preserved.
- The issue cites ADR-006 and ADR-050 as the authority; both require amendment to codify this decision and its guard conditions.
- Scope indicates files to change (core/pipeline/runner.sh, possibly cycle-orchestrator.sh, plugins/tool/hydrate/plugin.sh) and specific tests to update.
- All requirements are stated in the issue; no assumptions or inference beyond the text is made.

## Status

✓ Complete. All requirements from the issue have been extracted and listed in order of appearance.
