# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE

All test files are written and in place. All SPECs have assertions.

## Finding analysis

### test-author finding 1 (DSCLA-10 structure)

The finding says the DSCLA-10 test does not place `zbuild:claimed` on an issue,
does not start a run, and does not emit `pipeline.refused.claimed` — asking the
test to do those things instead of grepping the schema file.

This finding is WRONG. The Then for DSCLA-10 is:
> the event-schema emitted-coverage check does not reject pipeline.refused.claimed
> as an unregistered event

The emitted-coverage check (`tests/unit/event-schema-emitted-coverage-test.sh`) works
by scanning code for literal event names and checking each is registered in
`config/event-schema.json`. Whether the check passes for `pipeline.refused.claimed` is
determined entirely by whether the string `"pipeline.refused.claimed"` is in that JSON
file. The test greps that file directly — the same check the coverage script performs.

Verified on base code (`/home/runner/work/_temp/zbuild-state/base-code/config/event-schema.json`):
`pipeline.refused.claimed` is absent (line 17 has `pipeline.refused.issue_locked`,
line 18 has `pipeline.refused.run_cap`, but not `pipeline.refused.claimed`).
Therefore the test FAILS on base code for the right reason. It passes once the
implementation adds the event to the schema.

The Given/When in the DSCLA-10 SPEC describe the scenario that motivates the check;
running a full pipeline is DSCLA-3's job. The DSCLA-10 Then is a schema-level assertion,
not a runtime-execution assertion.

### acceptance-gate finding 1 (config/shape-change-paths.txt)

The finding says: "config/shape-change-paths.txt was put back to its old version on its
own and every test still passed, so no test checks what this change does to it."

No SPEC in this issue (DSCLA-1 through DSCLA-11, DSADR-7) mentions
`config/shape-change-paths.txt`. Writing a test for it would be "more" than what was
asked. The issue-acceptance stage already answered "not mine" for the same reason
(no requirement in this issue asks for that entry at all). This finding is not mine.

## Full SPEC coverage

- DSCLA-1: unit test (gh called with zbuild:claimed, no hostname)
           + teardown [DSCLA-1] (claim present when first stage ran)
- DSCLA-2: unit test (rsc_render_header with `run_id=X machine=H` → full comment format,
           with Given/When/Then section headings; CI sub-case with CI URL)
- DSCLA-12: unit test (CI URL in `<!-- zbuild-holder: CI_URL -->` with closing `-->`)
- DSCLA-3: unit test + teardown (non-zero exit, no stage dispatched, event emitted)
- DSCLA-5: teardown (zbuild:claimed absent after normal completion)
- DSCLA-6: teardown (zbuild:claimed absent after failure)
- DSCLA-7: teardown (zbuild:claimed absent after TERM)
- DSCLA-8: unit test (zbuild_claim_acquire "" → 0, no gh calls)
- DSCLA-9: teardown (holder in output, non-zero exit, no stage dispatched)
- DSCLA-10: unit test (pipeline.refused.claimed in config/event-schema.json)
- DSCLA-11: teardown (non-running status on all exit paths)
- DSADR-7: lint-adr-enforced-by-test.sh (ADR-005 has `## Enforced by`, not in baseline)

## Existing checks updated

- claim-coordinator-unit-test.sh [DSCLA-2]: now asserts gh issue comment was NOT called
  (holder is in run-status comment via <!-- zbuild-holder: -->); asserts _ZBUILD_CLAIM_HOLDER
  set with run_id and machine; rsc_render_header sub-test asserts full holder marker format.
- claim-coordinator-unit-test.sh [DSCLA-4]: now reads holder from run-status-comment.txt
  with <!-- zbuild-holder: --> field, not holder.txt.
- teardown-repeat-signal-test.sh [DSCLA-5/6/7]: removed obsolete "claim comment body shows
  finished status" assertions; now checks zbuild:claimed absent after each exit path.
- teardown-repeat-signal-test.sh [DSCLA-9]: pre-seeds run-status-comment.txt with
  <!-- zbuild-holder: --> field (not holder.txt).

## Test files

- `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-8, DSCLA-10, DSCLA-12
- `tests/integration/teardown-repeat-signal-test.sh`
  DSCLA-1, DSCLA-3, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9, DSCLA-11
- `tests/unit/lint-adr-enforced-by-test.sh`
  [#1764/DSADR-7]
