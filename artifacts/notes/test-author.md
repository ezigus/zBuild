# test-author notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — the target test file
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — the ADR being amended
- `scripts/lib/test-helpers.sh` — assert helpers, setup_test_env, etc.
- `scripts/lib/stage-result.sh` — stage_result_write function
- `core/pipeline/disposition.sh` — outcome vocabulary (timed_out, out_of_turns, interrupted, etc.)
- `docs/adr/design.md` — design artifact explaining the bug and fix

## Outcome vocabulary (from disposition.sh)

`outcome_vocabulary()` returns: `pass fail unusable timed_out out_of_turns interrupted
throttled rate_limited unavailable misconfigured broken`

Full non-pass set (10 words): `fail unusable timed_out out_of_turns interrupted throttled
rate_limited unavailable misconfigured broken`

## SPEC-1 judgment

**Requirement**: When any map member's outcome is not `pass`, `_strategy_run_map` exports
`ZBUILD_RUN_FLAGGED=yes`.

**SPEC-1-tagged assertions**: Three sub-tests asserting `ZBUILD_RUN_FLAGGED=yes` for
`timed_out`, `out_of_turns`, `interrupted` — 3 of 10 non-pass outcomes.

**Pre-existing M2 test** (same file, NOT tagged SPEC-1): covers `fail`. The test file
together covers 4 of 10 non-pass outcomes, but the SPEC-1 tag owns only 3.

**Logical gap**: An implementation:
  `[[ "$outcome" == timed_out || "$outcome" == out_of_turns || "$outcome" == interrupted ]] && flagged=yes`
would pass all three SPEC-1 assertions while failing for `fail`, `unusable`, `throttled`,
`rate_limited`, `unavailable`, `misconfigured`, `broken`. The three sub-tests do not force
a general "not pass" predicate.

**Verdict: partial** — the assertion tests the right behaviour for three specific "unfinished"
outcomes (the bug focus), but cannot establish "any non-pass" across the full outcome
vocabulary. `fail` and six other non-pass outcomes are outside the SPEC-1 tag's coverage.

## Second-pass confirmation (this turn)

Independently reached the same conclusion. The three SPEC-1-tagged sub-tests cover
`timed_out`, `out_of_turns`, `interrupted` — 3 of 10 non-pass outcomes from
`outcome_vocabulary()`. An implementation gated on exactly those three names would
pass all SPEC-1 assertions while silently ignoring `fail`, `unusable`, `throttled`,
`rate_limited`, `unavailable`, `misconfigured`, `broken`. The requirement's "any"
is not established by three specific cases.

## Status
- SPEC-1: judged **partial** (both passes agree)
