# spec-coverage checkpoint

## Files read
- /home/runner/work/_temp/zbuild-state/artifacts/design.md — 14 SPECs (SPEC-1 through SPEC-14), supersedes section listing affected tests, scope list of 47 files
- /home/runner/work/_temp/zbuild-state/artifacts/requirements.json — 13 requirements R-1 through R-13

## Conclusions reached

### R-1 — partially uncovered
SPEC-1 says "every dispatch route (map, fanout, sequential strategy, roleless leaf)" — four routes.
R-1 requires termination on seven routes: those four plus **cycle member**, **parallel-group member**, and **always_run**.
- cycle member and parallel-group member: not named by any SPEC
- always_run: SPEC-6 covers the config-source change (_runner_dispatch_always_run reads stage_timeout_s), SPEC-10 covers that kill goes through zbuild_pg_kill; but no SPEC states "a hung run hook on the always_run route ends timed_out at the limit"
- R-1 also requires testing "under every backend (bash-parallel, ruflo-hive, mock)"; no SPEC mentions the backend dimension

### R-2 — covered (SPEC-2)
### R-3 — covered (SPEC-3)
### R-4 — covered (SPEC-4)
### R-5 — covered (SPEC-5)

### R-6 — partially uncovered
SPEC-6 covers: release/persist values (30s/120s) and _runner_dispatch_always_run reading stage_timeout_s.
R-6 says "simple.yaml carries the values above" — the full table from the issue:
test: 90m, build: 70m, design: 65m, plan: 20m, test-author: 15m, acceptance-gate/etc: 10m, intake/etc: 10m.
No SPEC demands these values be present in simple.yaml. (The design summary mentions them but they are not in any SPEC.)

### R-7 — covered (SPEC-7)
### R-8 — covered (SPEC-8 covers deletion, guard, and misconfigured; "every test passes" is a verification outcome covered by R-13)
### R-9 — covered (SPEC-9)
### R-10 — covered (SPEC-10)
### R-11 — process/methodology requirement (grep discovery before writing tests); not a software behavior; can only be judged once change exists
### R-12 — covered (SPEC-11)
### R-13 — verification requirement ("npm test green"); can only be judged once change exists

## What is still unresolved
Nothing — all requirements checked. Verdict: UNCOVERED on R-1 and R-6.
