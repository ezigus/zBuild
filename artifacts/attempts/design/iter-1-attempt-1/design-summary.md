## design — fail

- the design fails 2 check(s)

- requirement R-7 from the issue is not covered by any SPEC: Before writing tests: `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s` and `_orch_local_kill_slot` in `tests/` — every test that pins them is in scope (CLAUDE.md, test scope discovery).. End the line of the SPEC that delivers it with " covers: R-7" (before any " evidence: "), or add a SPEC for it; if the code already does it, a [done] SPEC with evidence covers it
- requirement R-9 from the issue is not covered by any SPEC: `npm test` + `npm run lint` green.. End the line of the SPEC that delivers it with " covers: R-9" (before any " evidence: "), or add a SPEC for it; if the code already does it, a [done] SPEC with evidence covers it

This try is kept as the working copy for the next run; design.md is unchanged.
