# spec-coverage checkpoint (round 4)

## Files read
- `/home/runner/work/_temp/zbuild-state/cycle-design_verify_cycle/iter-2/feedback/design.txt` — 10 SPECs; iter-2 design revised SPEC-8 to describe test behavior (structural grep) rather than file contents.

## Key design facts
- Line 11: `export ZBUILD_NEGCTL_KILL_GRACE=...` is mandatory; bare assignment triggers SC2034
- Line 15: SPEC-8 closes detection gap — lint cannot detect retained inline probe pattern, structural grep test does
- Line 17: pre-existing legacy/ failures (ADR-059 §2) acknowledged; R-6 met for PR's own tests
- SPEC-8 revised from iter-1: now says "a structural test greps... and asserts (a)... and (b)..." — behavioral framing

## Finding analysis (round 4)

**design-gate finding 1**: SPEC-8 in iter-2 was revised to describe observable test behavior ("a structural test greps... asserts... exits 0/1"). Coverage judgment: SPEC-8 covers R-1 and R-2. The design-gate concern about form was addressed in iter-2. My job is coverage only — nothing to change.

**spec-correspondence finding 1** (SPEC-6 partial): SPEC-6 items (b)+(c)+(d) collectively require the ADR to name both the helper and the lint-failure statement. R-5 is covered. Assertion-quality judgment is spec-correspondence's domain; no spec gap.

**spec-correspondence finding 2** (SPEC-9 partial): SPEC-8 structurally verifies each site uses the pattern. SPEC-9 verifies runtime behavior of the helper. Together they cover R-1/R-3. Assertion quality is spec-correspondence's domain; no spec gap.

**issue-acceptance finding 1**: security-lens and scope-manifest failures are pre-existing ADR-059 §2 legacy-exclusion failures. Design line 17 acknowledges these explicitly. Not a spec gap for R-6.

**issue-acceptance finding 2**: SC2034 on ZBUILD_NEGCTL_KILL_GRACE — design line 11 explicitly mandates `export`. SPEC-10 requires the `export` bridge. Build deviated from the design's explicit instruction. Not a spec gap.

## Verdict
COVERED — all 6 requirements covered by 10 SPECs. Build-stage failures are deviations from design's explicit `export` mandate (not a spec gap) plus pre-existing legacy failures the design acknowledges (not a spec gap).
