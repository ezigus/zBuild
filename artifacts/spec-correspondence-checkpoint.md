# Spec-Correspondence Checkpoint

## Files read
- design.md: defines 6 SPECs; SPEC-1 through SPEC-4 are [code] and have assertions. Key details: _TPL_PR_DRAFT normalization runs before state check, both _draft_bool paths OR together.

## Conclusions reached

SPEC-1: PARTIAL. Assertion verifies that when state.status=failed, draft=true appears in pr-result.json and --draft is passed to gh. Does NOT test the "regardless of _TPL_PR_DRAFT" clause — no scenario with _TPL_PR_DRAFT explicitly false is exercised, so independence from TPL_PR_DRAFT is not established.

SPEC-2: CORRESPONDS. Requirement says forces _draft_bool=true before invoking gh when any cycle has max_iterations. Assertion checks draft=true in result and --draft in gh args. No "regardless of" qualifier in the requirement; observable outcome is fully verified.

SPEC-3: PARTIAL. Requirement says body names "iterations_used/max" (both values). Assertion only checks for the literal string "5" — a single number. This does not verify that both iterations_used and max are present; it covers one of the two required counts.

SPEC-4: CORRESPONDS. Requirement says body names failing gates and the gate-aggregator reason. Assertion checks two specific gate names (gate-security, gate-tests) and the reason phrase ("Security gate") — all named pieces of the requirement are verified.

## Nothing unresolved — all 4 SPECs judged.
