# Spec-coverage checkpoint — issue #1932 (current round)

## Files read
- design.md: 7 SPECs (SPEC-1 through SPEC-7), WIRING: runner.sh
- requirements.json: R-1 through R-8

## Conclusions

**R-1 (configurable cap, off unless set)**: Covered. SPEC-1 (unset → no-op, no slot file) + SPEC-2 (set+at-cap → refuse).

**R-2 (explicit refusal naming blockers)**: COVERED in current design.md. SPEC-2 now says "emits a refusal message to stderr that names every blocker" — gap from prior round is closed.

**R-3 (reap dead holders before admission using zbuild_run_is_live)**: Covered by SPEC-3.

**R-4 (operator override)**: Covered by SPEC-4 (ZBUILD_NO_RUN_CAP=1 → admit + warn).

**R-5 (single run and runs below cap byte-identically unaffected)**:
- SPEC-1: cap unset → writes no slot file, no output (single run case)
- SPEC-6: cap set, below cap → returns 0, writes slot file, produces no cap-related output. Gap from prior round is closed.

**R-6 (regression test driving cap+1 starts)**: Covered by SPEC-2 (N live slots + attempt = cap+1 → refused). "Reddens at merge-base" excluded per instructions.

**R-7 (fail-open test)**: Covered by SPEC-5 (slot dir unreadable → warns + admits).

**R-8 (ADR-059 amended with Enforced-by entry)**: Covered by SPEC-7.

## Final verdict
All 8 requirements are covered. No gaps remain.
