# Spec-coverage checkpoint — issue #1932

## Files read
- design.md: 6 SPECs (SPEC-1 through SPEC-6), WIRING: runner.sh, 7 scope files
- requirements.json: R-1 through R-8

## Conclusions so far

**R-1 (configurable cap, off unless set)**: Covered. SPEC-1 tests unset → no-op; SPEC-2 tests set+at-cap → refuse.

**R-2 (explicit refusal naming blockers)**: GAP. SPEC-2 says the function returns 1 and sets `_ZBUILD_RUN_CAP_BLOCKERS`, but does NOT require that a message is emitted to the operator. "Explicit" in R-2 means the operator sees why the run was refused. No SPEC covers emission of the refusal message from runner.sh.

**R-3 (reap dead holders before admission using zbuild_run_is_live)**: Covered by SPEC-3.

**R-4 (operator override)**: Covered by SPEC-4.

**R-5 (single run and runs below cap are byte-identically unaffected)**: PARTIAL GAP. SPEC-1 covers "single run" (cap unset → no-op). No SPEC covers "runs below the cap" (cap set but not exceeded; run admitted). SPEC-1 claims R-5 but only tests the no-cap case; the below-cap case is absent from every SPEC.

**R-6 (regression test driving cap+1 starts)**: Covered by SPEC-2 (tests with N live slots and cap=N). "Reddens at merge-base" is a process requirement excluded per instructions.

**R-7 (fail-open test)**: Covered by SPEC-5 (slot dir unreadable → warns + admits).

**R-8 (ADR-059 amended with Enforced-by entry)**: Covered by SPEC-6.

## RESUMED RUN — additional findings

Read design.txt (iter-2/feedback/design.txt directly). Confirmed: the actual design file has 6 SPECs. 

CRITICAL DISCREPANCY: The ACCEPTANCE section in this prompt shows 7 SPECs that differ from design.txt:
- Prompt SPEC-2 adds "emits a refusal message to stderr that names every blocker" — absent from design.txt SPEC-2
- Prompt SPEC-6[code] (below-cap case: "with cap N set and fewer than N live slot files present...") — does NOT exist in design.txt
- Prompt SPEC-7[no-code] = design.txt SPEC-6[no-code], renumbered

The design.txt is the artifact at the given path and is authoritative. The ACCEPTANCE section appears to show proposed/revised SPECs not yet in the design.

Prior checkpoint conclusions CONFIRMED against design.txt:
- R-2 gap confirmed: design.txt SPEC-2 sets variable but emits no message
- R-5 gap confirmed: no below-cap SPEC exists in design.txt

## Final verdict
UNCOVERED: R-2 (explicit emitted message not demanded) and R-5 (below-cap case absent).
