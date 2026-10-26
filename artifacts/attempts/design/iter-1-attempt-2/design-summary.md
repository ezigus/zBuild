## design — fail

- the design fails 2 check(s)

- The issue asks for this and no SPEC covers it: R-1: SPEC-1 says the stage outcome is `timed_out` but does not demand the outcome names the stage and the timeout limit exceeded — R-1 explicitly requires "ends `timed_out` naming the stage and the limit"
- The issue asks for this and no SPEC covers it: R-4: SPEC-2 covers "any name that resolves to no plugin" and SPEC-4 covers "plugin absent from the installed tree" but no SPEC covers the "or an unreadable config" branch of R-4 — a backend whose config exists but cannot be read must also fail as `misconfigured` naming the backend

This try is kept as the working copy for the next run; design.md is unchanged.
