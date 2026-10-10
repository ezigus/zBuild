# Spec Correspondence Checkpoint

## Files read
- design.md: read in full — 7 SPECs, requirements about fork reduction, timestamp fix (ZBUILD_PLATFORM vs OSTYPE), sidecar self-trigger loop, redundant PATCH prevention

## Conclusions reached

SPEC-1: PARTIAL
- Assertion checks no `%3N` and ISO 8601 regex — correct output properties
- Does NOT verify preconditions (ZBUILD_PLATFORM=linux, OSTYPE=darwin*) were in effect
- Could pass on a Linux host where the mac-specific code path was never exercised

SPEC-2: PARTIAL
- Negative check (old pattern absent) + 4 field spot-checks
- "Byte-for-byte identical" requires full output comparison — 4 fields don't establish that

SPEC-3: PARTIAL
- Tests behavioral outcome (no spurious PATCH) — correct consequence
- Requirement names the mechanism (cursor reset) — that mechanism is not verified
- A different implementation preventing the second render would also pass

SPEC-4: CORRESPONDS
- No additional PATCH after first one — directly maps to requirement

SPEC-5: CORRESPONDS
- Checks all events for stage="run-status-comment", correctly catches missing stage (null != "run-status-comment" is true)
- Guards on at least one event being present first

## All 5 SPECs judged. Nothing unresolved.
