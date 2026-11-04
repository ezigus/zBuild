## design — fail

- the design fails 1 check(s)

- FRSH-2 Then 1 says how it is built, not what it does: describes an internal code path ("the guard is not entered because resume_mode is false"), not an observable output a test can assert after the When; the observable outcome is Then 2 (all stages dispatched) — "The skip-stage guard is not entered because resume_mode is false". Say what someone could see happen instead

This try is kept as the working copy for the next run; design.md is unchanged.
