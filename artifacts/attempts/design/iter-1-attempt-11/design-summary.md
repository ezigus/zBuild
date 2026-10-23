## design — fail

- the design fails 2 check(s)

- The issue asks for this and no SPEC covers it: R-11: SPEC-15 demands grep for orch-sequential, ZBUILD_ORCH_TIMEOUT, and router.timeout_s but omits the always_run watchdog grep — R-11 requires all four patterns be grepped before writing tests so that every test pinning the old always_run dispatch watchdog behaviour is discovered and in scope
- The issue asks for this and no SPEC covers it: without it, tests pinning the hand-rolled kill sequence in _runner_dispatch_always_run may be missed, causing the build-loop failures CLAUDE.md warns about

This try is kept as the working copy for the next run; design.md is unchanged.
