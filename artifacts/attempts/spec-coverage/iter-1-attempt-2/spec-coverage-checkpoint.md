# spec-coverage checkpoint (round 3)

## Files read
- `/home/runner/work/_temp/zbuild-state/artifacts/design.md` — 10 SPECs (SPEC-1 through SPEC-10); now matches prompt ACCEPTANCE section exactly. Design is authoritative.

## Key design facts this round
- design.md line 11: explicitly says `export ZBUILD_NEGCTL_KILL_GRACE=...` is **mandatory** and explains SC2034 is the reason
- design.md line 17: explicitly acknowledges security-lens and scope-manifest pre-existing failures as ADR-059 §2 legacy-exclusion failures not caused by this PR
- SPEC-10 explicitly references `export ZBUILD_NEGCTL_KILL_GRACE="${CALLER_VAR:-10}"` as the mandated bridging pattern

## Findings analysis

**spec-correspondence finding 1** (SPEC-6 partial):
The assertion doesn't fully verify the "every timeout bound resolves through helper" scoped statement. From spec-coverage perspective: SPEC-6 items (b)+(c)+(d) collectively require the ADR to reference both the helper and the lint-failure statement; the scoped rule is implied by those three items together. R-5 remains covered. This is an assertion-quality issue (spec-correspondence's domain), not a spec gap.

**spec-correspondence finding 2** (SPEC-9 partial):
Tests call helper directly, not via site wrapping code. SPEC-8 structurally verifies each site uses the pattern and drops the inline probe. SPEC-9 verifies runtime behavior. Together they cover R-1/R-3. Assertion quality is spec-correspondence's domain; no spec gap.

**issue-acceptance finding 1** (pre-existing test failures):
security-lens-test.sh and scope-manifest-b1-regression-test.sh fail from missing legacy/ tree (ADR-059 §2). Design line 17 explicitly acknowledges these as pre-existing failures unrelated to this PR. Not a spec gap.

**issue-acceptance finding 2** (SC2034 on ZBUILD_NEGCTL_KILL_GRACE):
run-tests.sh:36 and run-mutation.sh:125 assigned without `export`, triggering SC2034. Design line 11 explicitly requires `export` and explains why. SPEC-10 mandates `export ZBUILD_NEGCTL_KILL_GRACE`. The build stage violated the design's explicit instruction — a build failure, not a spec gap.

## Verdict
COVERED — all 6 requirements covered by 10 SPECs. Issue-acceptance failures are build-stage deviations from the design's explicit `export` mandate plus pre-existing legacy failures the design acknowledges.
