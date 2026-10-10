# Spec Correspondence Checkpoint

## Files read
- design.md: read in full — 7 SPECs, requirements about fork reduction, timestamp fix (ZBUILD_PLATFORM vs OSTYPE), sidecar self-trigger loop, redundant PATCH prevention

## Conclusions reached

SPEC-1: PARTIAL
- Assertion checks no `%3N` and ISO 8601 regex — correct output properties
- Does NOT verify preconditions (ZBUILD_PLATFORM=linux, OSTYPE=darwin*) were in effect when the test ran
- Could pass on a Linux host where the mac-specific code path was never exercised

SPEC-2: PARTIAL
- jq call count check (1-arg vs 3-arg) verifies accumulation mechanism
- "Byte-for-byte identical" requires full output comparison — 4 spot-checked fields don't establish that

SPEC-3: PARTIAL
- Tests behavioral outcome (no spurious PATCH) — correct consequence of the cursor reset
- Requirement names the mechanism (cursor reset); assertion doesn't verify cursor was updated
- A different implementation preventing the second render would also pass

SPEC-4: PARTIAL
- "First PATCH fired" confirms sidecar ran; "0 subsequent PATCHes" tests the suppression outcome
- Assertion doesn't verify that an identical-body second flush was *attempted* — if no second flush
  occurs for any reason, 0 PATCHes is vacuously true and the suppression logic is not exercised

SPEC-5: PARTIAL
- Checks all events in SC5_EVENTS carry stage="run-status-comment"
- Verifies at least one event is present and that apply_scope_redaction ran (POST check)
- Does NOT verify redaction.applied events specifically appear in SC5_EVENTS; if those events go to
  a different path or are absent, the check is vacuously true for the "(including redaction.applied)"
  condition the requirement calls out as the key concern

SPEC-6: PARTIAL
- Verifies patched code is within FORK_BUDGET (_total <= FORK_BUDGET)
- Does NOT establish FORK_BUDGET is set to a value smaller than merge-base measurement
- Does NOT verify unpatched code would fail (negative-control condition not exercisable at head)

## Nothing unresolved — all 6 SPECs judged.
