## test-author — pass

- tests for DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21, DSCLA-22, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8, DSCLA-14

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TAFND-4: done — Changed the stub `_dscla19_stub_claim` to write its received argument (`printf '%s\n' "$_issue"`) into the marker file instead of just touching it, then changed the Then assertion from `[[ -e "$_dscla19_hook_called" ]]` to `grep -Fxq "$_dscla19_issue" "$_dscla19_hook_called"`. Now the test fails if the wrong issue number (or empty string) is forwarded to the hook.
- answered: IAFND-1: done — Updated `tests/golden/parity/event-sequence.golden` (a test folder file, mine to change) by applying the diff the failing test reported: inserted `plugin.claim.start` and `plugin.claim.complete` after `pipeline.init`, and appended `plugin.release.start` and `plugin.release.complete` after the final `plugin.run.complete`. The golden file now reflects the four events the claim coordinator emits on a normal run.
