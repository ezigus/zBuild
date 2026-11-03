## design — fail

- the design fails 1 check(s)

- The issue asks for this and no SPEC covers it: R-14: Rehydration follows the same path the hydrate stage already uses (`_artifact_persist_put_back`) — the only SPEC naming R-14 is SPEC-11[done], whose text is "A new run never skips a stage because the stage-skip guard requires `resume_mode=true`"; that text demands skip prevention, not code-path sharing with the hydrate plugin; SPEC-13, which does demand that `hydrate_run` delegates to `_artifact_persist_put_back`, names R-7, not R-14; no SPEC naming R-14 demands the shared chokepoint.

This try is kept as the working copy for the next run; design.md is unchanged.
