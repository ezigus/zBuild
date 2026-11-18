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
`pipeline.refused.claimed` is absent (`pipeline.refused.issue_locked` and
`pipeline.refused.run_cap` are present, but not `pipeline.refused.claimed`).
Therefore the test FAILS on base code for the right reason. It passes once the
implementation adds the event to the schema.

The Given/When in the DSCLA-10 SPEC describe the scenario that motivates the check;
running a full pipeline is DSCLA-3's job. The DSCLA-10 Then is a schema-level assertion,
not a runtime-execution assertion.

### acceptance-gate finding 1 (config/shape-change-paths.txt)

The finding says: "config/shape-change-paths.txt was put back to its old version on its
own and every test still passed, so no test checks what this change does to it."

No SPEC in this issue (DSCLA-1 through DSCLA-13, DSADR-7) mentions
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
- DSCLA-13: teardown (zbuild:claimed absent after second SIGTERM during abort trap)
- DSADR-7: lint-adr-enforced-by-test.sh (ADR-005 has `## Enforced by`, not in baseline)

## DSCLA-13 test design

DSCLA-13 requires: when _runner_abort_trap blocks SIGTERM (via `trap '' TERM`) and a
second SIGTERM arrives while zbuild_claim_release is executing inside the trap,
zbuild:claimed is still removed.

Approach (in tests/integration/teardown-repeat-signal-test.sh, after DSCLA-11):
1. Add a `claim-dscla13.yaml` template to `$_CLAIM_REPO` — has an always-run `release`
   stage (role: teardown). The always-run stage writes a marker when entered, confirming
   we are inside `_runner_abort_trap` with SIGTERM blocked.
2. Stage starts, `_DSCLA13_PRESENT` is set (zbuild:claimed was in claim store).
3. First SIGTERM → _runner_abort_trap fires, does `trap '' TERM`.
4. Wait for teardown/release stage to write `_DSCLA13_ABORT_ENTERED` (we are inside trap).
5. Second SIGTERM — arrives during abort trap execution (SIGTERM is blocked, ignored).
6. Wait for runner to exit.
7. Gate assertion on `_DSCLA13_PRESENT` (fails on base code since zbuild_claim_acquire
   is never called in base runner.sh).
8. Assert `zbuild:claimed` absent from `$ZBUILD_CLAIM_STORE/90001769/labels.txt`.

Fails on base code: zbuild_claim_acquire is not called → zbuild:claimed is never added
→ _DSCLA13_PRESENT is never created → gate assertion fires as assert_fail.

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
  DSCLA-1, DSCLA-3, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9, DSCLA-11, DSCLA-13
- `tests/unit/lint-adr-enforced-by-test.sh`
  [#1764/DSADR-7]
