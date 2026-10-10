# Open items the run could not settle

The run used its last round with these items still open, and no stage that ran could act on them.

1. **issue-acceptance finding 1** (opened by issue-acceptance): Not sure this requirement is met: R-1: the diff cannot confirm the red step was stated in the PR body — that documentation requirement is not visible in any changed file.
   - What would settle it: a test that fails when this requirement is not met, or the code or document that shows it is met.
   - build: nothing to do — not reproduced: tests/unit/impact-max-turns-test.sh now uses an inline fixture (test-author commit 55481a29), all 3 tests pass
   - design: done — added `tests/unit/impact-max-turns-test.sh` to scope with SPEC-8[no-code] requiring it be refactored to load an inline fixture instead of simple.yaml (so its router assertions remain valid after impact is removed from the template)
   - spec-correspondence: nothing to do — spec-correspondence judges assertion-to-requirement pairs only; it does not modify implementation files or fix failing tests.
   - spec-coverage: nothing to do — SPEC-8[no-code] in the design covers R-2 by specifying impact-max-turns-test.sh must use an inline fixture; the failure is an implementation gap, not a design gap
   - test-author: done — replaced `load_template simple.yaml` with an inline fixture in impact-max-turns-test.sh (SPEC-8); the fixture declares the impact stage with `router.max_turns: 45` and `router.timeout_s: 600` so all three assertions now read from a template that has impact
2. **issue-acceptance finding 2** (opened by issue-acceptance): Not sure this requirement is met: R-5: a dogfood run completing with no impact stage and no stage-resolution warning has not been observed — the current pipeline run dispatched impact (verdict: warn), which is consistent with running on the old templates, but provides no evidence of a clean post-merge run.
   - What would settle it: a test that fails when this requirement is not met, or the code or document that shows it is met.
   - build: nothing to do — not reproduced: impact-max-turns-test.sh no longer calls `load_template simple.yaml`; the inline fixture makes all assertions pass
   - design: done — same as finding 1; SPEC-8 covers both the scope addition and the required fix
   - spec-correspondence: nothing to do — spec-correspondence judges assertion-to-requirement pairs only; it does not modify implementation files or fix failing tests.
   - spec-coverage: nothing to do — SPEC-8 specifies exactly the fix needed (replace load_template simple.yaml with inline fixture); the design covers this; the build stage must apply it
   - test-author: done — same change as finding 1; the inline fixture supplies the impact stage vars that `template_stage_router_max_turns` and `template_stage_router_timeout` read, so all three assertions now pass
3. **issue-acceptance finding 5** (opened by issue-acceptance): no words were given for it
   - What would settle it: the issue-acceptance check no longer reports it when it runs again: a change that resolves it, or evidence that it is already resolved
   - build: nothing to do — this is a "not sure" finding about the PR body, not a code defect; SPEC-18 and SPEC-7 assertions exist and pass, which is what the test suite can verify
   - design: nothing to do — "state the red step in the PR body" is a human-authored PR description requirement; the design captures it structurally via SPEC-1 and SPEC-7 as `[code]` requirements whose test assertions fail on main; the specific PR body text cannot be verified by a test and is outside the design scope
   - spec-correspondence: nothing to do — spec-correspondence judges assertion-to-requirement pairs only; it does not modify implementation files or fix failing tests.
   - spec-coverage: nothing to do — "state the red step in the PR body" is a process requirement verifiable only once the PR is created; deferred per spec-coverage instructions; the reddens-on-main behavior is covered by SPEC-1 and SPEC-7
   - test-author: nothing to do — the "state the red step in the PR body" requirement is about PR description content, not testfile content; it is outside test-author's scope
