# Design-rooted gate feedback

The build_test_cycle cannot fix these — they route back to design.
Re-author the named acceptance assertions, then the pipeline re-verifies.

## shape-floor

- reason: missing_floor_files

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-1/SPEC-2/SPEC-3/SPEC-4/SPEC-5/SPEC-6/SPEC-7/SPEC-8/SPEC-11 tautological (pass at baseline) — re-author the assertions; SPEC-9 tagged as [guard] but the assertion FAILS at the merge-base — a guard must hold there by definition, so either the assertion contradicts its SPEC text or the SPEC is a mislabelled [change]
- failures:
    - tautology:SPEC-1
    - tautology:SPEC-2
    - tautology:SPEC-3
    - tautology:SPEC-4
    - tautology:SPEC-5
    - tautology:SPEC-6
    - tautology:SPEC-7
    - tautology:SPEC-8
    - guard_regressed:SPEC-9
    - tautology:SPEC-11

