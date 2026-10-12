# Design-gate: structural violations

The design is not ready to build. Fix these and write design.md again:

- requirement R-11 from the issue is not covered by any SPEC: Before writing tests: `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `router.timeout_s` and the `always_run` watchdog in `tests/` — every test that pins them is in scope (CLAUDE.md, test scope discovery).. End the line of the SPEC that delivers it with " covers: R-11" (before any " evidence: "), or add a SPEC for it; if the code already does it, a [done] SPEC with evidence covers it
- requirement R-13 from the issue is not covered by any SPEC: `npm test` + `npm run lint` green.. End the line of the SPEC that delivers it with " covers: R-13" (before any " evidence: "), or add a SPEC for it; if the code already does it, a [done] SPEC with evidence covers it
