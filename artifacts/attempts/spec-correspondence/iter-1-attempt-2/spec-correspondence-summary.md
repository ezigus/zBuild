## spec-correspondence — partial

- judged 1 SPEC(s): 0 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-3 partial: The assertion sweeps all production code directories and verifies the six named sites, but excludes `tests/` entirely from the R-4 greps (where non-historical disposition-label uses could still exist), and verifies the "dated" aspect of the backward-pointer note only for ADR-054 (via an explicit ISO-date check) — not for ADR-001, whose annotation is only confirmed to reference `#2187` with no date-format check.

