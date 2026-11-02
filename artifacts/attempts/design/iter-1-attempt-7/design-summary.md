## design — fail

- the design fails 3 check(s)

- the issue does not ask for this, or the design gets it wrong: SPEC-13 covers only R-15, which is not among R-1–R-14
- the issue does not ask for this, or the design gets it wrong: no listed requirement asks that every test file use a pipeline containing a cyclic stage — R-9 only requires loop-resume iteration-state restore to work correctly, which is addressed by SPEC-7 alone
- the issue does not ask for this, or the design gets it wrong: SPEC-5 also references R-15 (naming enforcing tests inline in the ADR) beyond what R-5 strictly requires, though its R-5 coverage (amend ADR-006 with step 3.6) is valid on its own

This try is kept as the working copy for the next run; design.md is unchanged.
