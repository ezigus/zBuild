# Spec-Correspondence Checkpoint

## Files read
- design.md (lines 1-80): confirmed design intent for all 9 SPECs — (A) engine suppression block, (B) plugin router-rc classification, (C) ADR-063 amendment

## Conclusions reached

SPEC-1: partial — assertion tests only timed_out disposition; requirement covers timed_out, out_of_turns, and interrupted
SPEC-2: corresponds — all four assertion checks (rc=0, reason=converged, 0 suppression events, 1 dispatch) fully establish the requirement
SPEC-3: partial — assertion tests only rc=124; requirement says "exits non-zero" broadly (rc=124 is parenthetical example)
SPEC-4: partial — assertion tests only rc=1; requirement says "exits non-zero" without restricting to one value
SPEC-5: partial — assertion tests single failing lens; requirement says "one or more" and "first failed lens rc" is only tested in the one-lens case
SPEC-6: corresponds — all outcome checks (term_rc=8, cycle.timeout_exhausted, reason=design_timeout_exhausted, terminated_reason) fully establish the requirement
SPEC-7: partial — checks old vocabulary absent but does not verify new vocabulary (timed_out/out_of_turns) is present
SPEC-8: partial — checks _budget_guidance present (>0 occurrences) but not that each stage has its own helper
SPEC-9: partial — checks #2187 appears anywhere; does not verify it is specifically an amendment back-pointer

## Nothing unresolved — verdicts complete
