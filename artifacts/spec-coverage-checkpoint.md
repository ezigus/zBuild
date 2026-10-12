# spec-coverage checkpoint

## Files read (this run)
- /home/runner/work/_temp/zbuild-state/artifacts/design.md — current design: SPEC-1 through SPEC-16, SPEC-18 (SPEC-17 removed as tautology; SPEC-18 added for event schema registration)

## Key changes from prior design
- SPEC-17 removed: was a tautology (asserted orch-mock/plugin.sh exists — true before and after). Backend-agnostic property absorbed into SPEC-1's description.
- SPEC-18 added: orch.backend.misconfigured and plugin.run.timed_out registered in event-schema.json; covers R-1 and R-8.
- SPEC-2 expanded: external-SIGTERM path also kills isolated hook process group.
- SPEC-8 guard exclusion: now explicitly excludes orch-backend-misconfigured-test.sh.
- set -m leakage and runner-job-control-abort-test.sh added to scope notes.

## Coverage conclusions (this round)

R-1: COVERED by SPEC-1 (all 7 routes, all 3 backends, timed_out naming stage+limit) + SPEC-18.
R-2: COVERED by SPEC-2 (whole group, TERM+10s, both internal and external-SIGTERM paths).
R-3: COVERED by SPEC-3 (template > env > 5400s, each tier in isolation).
R-4: COVERED by SPEC-4 (rejects below router.timeout_s AND non-integer).
R-5: COVERED by SPEC-5 (retry AND each map member get fresh timer).
R-6: COVERED by SPEC-6 (all values listed, always_run reads stage_timeout_s, no router.timeout_s on always_run).
R-7: COVERED by SPEC-7 (no ZBUILD_ORCH_TIMEOUT, plan > 300s within stage_timeout_s completes).
R-8: COVERED by SPEC-8 (absent directory, guard with correct exclusions, sequential→misconfigured).
R-9: COVERED by SPEC-9 (missing/unreadable→misconfigured naming backend, from installed tree).
R-10: COVERED by SPEC-10 (both locations use zbuild_pg_kill, no hand-rolled TERM/KILL).
R-11: COVERED by SPEC-15 no-code (grep-rl performed, every pinning test in scope).
R-12: COVERED by SPEC-11 no-code (ADRs amended with Enforced by, removed from baseline).
R-13: COVERED by SPEC-16 no-code (npm test + npm run lint pass).

## Final verdict: COVERED
