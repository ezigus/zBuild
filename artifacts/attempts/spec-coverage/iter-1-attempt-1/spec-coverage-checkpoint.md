# Spec-coverage checkpoint

## Files read
- design.md: 6 SPECs (SPEC-1 through SPEC-6); SPEC-1/2 are [code] forcing draft on failed/max_iterations; SPEC-3/4 cover body content; SPEC-5/6 are [done] covering passing-run and explicit pr_draft setting.
- requirements.json: 7 requirements R-1 through R-7.

## Conclusions

R-1 → SPEC-1 fully covers (forces draft on state.status=failed).
R-2 → SPEC-2 fully covers (forces draft on max_iterations cycle).
R-3 → SPEC-3 names cycle/iterations; SPEC-4 names failing gates and reason (conditioned on gate_aggregator_result presence — appropriate since failing gates only exist when that file exists).
R-4 → SPEC-3 covers iterations_used/max and "not converged" phrase.
R-5 → SPEC-5 [done] covers passing converged run stays non-draft.
R-6 → SPEC-6 [done] covers explicit pr_draft:true overrides.
R-7 → SPEC-1 and SPEC-2 both list R-7 and name test files; "red on main" part is verification-only and excluded from this stage's judgment.

## Verdict
COVERED — all 7 requirements are addressed by at least one SPEC.

## Nothing left to resolve.
