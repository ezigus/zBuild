# Spec-Correspondence Checkpoint

## Files read
- design.md (lines 1-80): confirmed design intent for all 9 SPECs — (A) engine suppression block, (B) plugin router-rc classification, (C) ADR-063 amendment
- Stage inputs re-read: all assertions reviewed in detail for second and third pass

## Final verdicts (third pass)

SPEC-1: corresponds — assertion tests ALL THREE dispositions (timed_out, out_of_turns, interrupted) in three separate _run_cycle calls
SPEC-2: corresponds — all four checks (rc=0, reason=converged, 0 suppression events, 1 dispatch) fully establish the requirement
SPEC-3: corresponds — tests rc=124→timed_out and rc=1→unavailable; establishes classification not hardcoded
SPEC-4: corresponds — same reasoning; tests rc=1→unavailable and rc=124→timed_out for spec-correspondence plugin
SPEC-5: corresponds — requirement says "classified from a failed lens rc" (not "first lens wins"); all three test cases establish disposition comes from a failed rc not hardcoded complete; mixed-rc case (correctness rc=124, others rc=1 → timed_out) establishes ordering beyond the requirement minimum
SPEC-6: corresponds — all four outcome checks (term_rc=8, event emitted, reason=design_timeout_exhausted, terminated_reason) fully establish the requirement
SPEC-7: corresponds — checks both absence of old vocabulary AND presence of replacement vocabulary (timed_out>0, out_of_turns>0)
SPEC-8: corresponds — requirement parenthesizes "(more than one unique helper name present)" as the explicit criterion; assertion checks distinct > 1 which is exactly that; "per-stage" in the requirement is descriptive, not a coverage claim about every stage
SPEC-9: corresponds — 'mend.*#2187|#2187.*mend' grep establishes amendment context specifically

## Acceptance-gate finding
Finding 1: nothing to do — wiring correctness (config/event-schema.json reachability) is outside spec-correspondence scope; spec-correspondence judges whether assertions establish requirements
