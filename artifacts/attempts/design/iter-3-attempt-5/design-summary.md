## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: done — DSFRSH-2's Then clause was too vague ("Every stage emits a stage.start event") and led the test-author to write a narrow assertion checking only that intake emits one stage.start, which passes even if other stages never emit it. Changed the Then to "The count of stage.start events in the event log equals the total number of stages declared in the pipeline fixture (every stage dispatched, not just the first)". This requires the test to count all stage.start events across the fixture and assert the total equals the stage count — which fails if any stage is silently skipped. Added Finding 29 documenting the change.
