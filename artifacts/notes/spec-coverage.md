# spec-coverage notes — issue #1801

## Context
Second run of spec-coverage. Previous run found 3 gaps:
- R-1: parallel-group member absent from route list + no per-backend test demand
- R-8: fixture migration not demanded by any SPEC
- R-9: installed-tree test not demanded by any SPEC

Design was revised: SPEC-1 updated; SPEC-17 added; SPEC-19 added.

## R-1 check
SPEC-1 now enumerates: map, fanout, sequential strategy, cycle member, parallel-group
member, roleless leaf, always_run. Gap 1a closed.

SPEC-1 now says "the watchdog is above the backend layer and therefore covers bash-parallel,
ruflo-hive, and mock backends by construction." This is a behavioral demand for all three
backends; the architectural argument is the justification for why a single test suffices.
Gap 1b closed.

"Regression test reddens at merge-base" — process/test-first step; per instructions
cannot be judged here and does not go in UNCOVERED.

## R-2: whole process group dies after TERM + 10 s
SPEC-2 (set -m, TERM trap kills inner group) + SPEC-13[done] (zbuild_pg_kill TERM+KILL).
Covered.

## R-3: precedence each layer tested
SPEC-3 with isolation test for 5400 s default. Covered.

## R-4: loader validation
SPEC-4 matches exactly. Covered.

## R-5: fresh timer per retry and map member
SPEC-5: watchdog instantiated inside plugin_hook_call per dispatch call. Covered.

## R-6: simple.yaml values; always_run reads stage_timeout_s not router.timeout_s
SPEC-6: all parts matched. Covered.

## R-7: strategies pass no flat limit; plan > 300 s completes
SPEC-7: ZBUILD_ORCH_TIMEOUT absent; 310 s sleep test passes. Covered.

## R-8: orch-sequential retired
SPEC-8 (dir absent, no file outside adr/ names it, config naming sequential misconfigured)
+ SPEC-17 (fixture migration enforced mechanically by guard). Previous gap closed. Covered.

## R-9: misconfigured backend, tested from installed tree
SPEC-9 (both cases, output names backend) + SPEC-19 (installed-tree variant).
Previous gap closed. Covered.

## R-10: zbuild_pg_kill everywhere, no hand-rolled kill
SPEC-10 names all three call sites. Covered.

## R-11: test scope discovery (grep 4 terms before writing)
SPEC-15[no-code] covers 3/4 terms (missing "always_run watchdog"). But R-11 is a
development-process step ("before writing tests, grep…") analogous to "tests fail at
merge-base." Per instructions this cannot be judged here and does not go in UNCOVERED.

## R-12: ADR Enforced-by sections
SPEC-11[no-code]. Covered.

## R-13: npm test + lint green
SPEC-16[no-code]. Process requirement. Covered.

## Verdict
All three previous gaps closed. No new gaps. VERDICT: covered.
