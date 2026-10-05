# Spec-Correspondence Checkpoint

## Files read
- design.md (lines 1-80): confirmed design intent for all 9 SPECs — (A) engine suppression block, (B) plugin router-rc classification, (C) ADR-063 amendment
- Stage inputs re-read: all assertions reviewed in detail for second pass

## Revised conclusions (corrects prior checkpoint errors)

SPEC-1: corresponds — assertion tests ALL THREE dispositions (timed_out, out_of_turns, interrupted) in three separate _run_cycle calls; prior "partial" was wrong
SPEC-2: corresponds — all four checks (rc=0, reason=converged, 0 suppression events, 1 dispatch) fully establish the requirement
SPEC-3: corresponds — tests two distinct non-zero rcs (rc=124→timed_out, rc=1→unavailable), establishing classification via router_reason_disposition is in use (not hardcoded complete)
SPEC-4: corresponds — same reasoning as SPEC-3, tests rc=1→unavailable and rc=124→timed_out
SPEC-5: partial — "first failed lens rc" semantics not established; multi-lens test (_RR_FAIL_ALL_RC=1) has all lenses fail at same rc=1, so no case distinguishes first vs. other lens rcs
SPEC-6: corresponds — all four outcome checks (term_rc=8, event emitted, reason, terminated_reason) fully establish the requirement
SPEC-7: corresponds — checks both absence of old vocabulary (exhausted/escalate patterns) AND presence of new vocabulary (timed_out count>0, out_of_turns count>0); prior "partial" was wrong
SPEC-8: partial — assertion checks distinct helpers > 1, but requirement says "each stage has its own"; >1 helpers doesn't prove every stage has one
SPEC-9: corresponds — second assertion grep('mend.*#2187\|#2187.*mend') specifically checks amendment context; prior "partial" was wrong

## Nothing unresolved — verdicts complete
