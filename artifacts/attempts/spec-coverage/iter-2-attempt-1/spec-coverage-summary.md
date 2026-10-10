## spec-coverage — uncovered

- SPEC-2 requires the function set _ZBUILD_RUN_CAP_BLOCKERS but demands no emitted message to stderr, leaving R-2's "explicit" refusal unverified; and no SPEC covers the below-cap path (cap set, live count < N), leaving half of R-5 unverified.

- NOT COVERED: R-2 (SPEC-2 demands the function return 1 and set _ZBUILD_RUN_CAP_BLOCKERS naming blockers but does not require any message be emitted to stderr — an operator who cannot inspect the variable sees no explicit refusal and no explanation of what is blocking the run)
- NOT COVERED: R-5 (SPEC-1 covers only the unset-cap case and claims "covers: R-5" — the below-cap case where cap is configured but live count is below N is absent from every SPEC, so "runs below the cap are byte-identically unaffected" is untested)
