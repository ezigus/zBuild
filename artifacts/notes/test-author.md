# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE (pass 8)

## Changes in pass 8

### plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh

1. **DSCLA-2 render sub-test section structure**: The rsc_render_header render block
   previously sat under a `# Then:` comment label with no `# Given:` / `# When:`. Now
   the block has explicit:
   - `# Given: a local run (GITHUB_ACTIONS not true)…` before the setup
   - `# When: rsc_render_header is called with the run id and holder string` right before
     the `rsc_render_header` call
   - `# Then:` block already present (kept as-is)

2. **DSCLA-12 grep includes closing `-->`**: Changed
   `grep -qF "<!-- zbuild-holder: $_dscla12_ci_url"` to
   `grep -qF "<!-- zbuild-holder: $_dscla12_ci_url -->"` and updated the fail message
   to include `-->`. Without the closing marker the assertion passes when the comment
   is malformed (opening marker present, closing absent).

## Findings answered this pass

- **test-author finding 1 (DSCLA-2 section layout)**: done — rsc_render_header call now
  has its own `# Given:` and `# When: rsc_render_header is called with the run id and
  holder string` section labels above it; the `# Then:` block already existed.

- **test-author finding 2 (DSCLA-12 missing `-->`)**: done — added ` -->` to the
  `grep -qF` pattern and updated the assert_fail message to include `-->`.

- **test-author finding 3 (DSCLA-10 Given/When)**: wrong — the SPEC's `Then` says
  "the event-schema emitted-coverage check does not fail on pipeline.refused.claimed
  as an unregistered event". The coverage check IS "is the event in the JSON file?"
  Grepping the file is the correct test. The Given/When describe motivation; the
  assertion is at the right level.

- **acceptance-gate finding 1 (baseline reversion)**: wrong — when the baseline is
  reverted to its old version (ADR-005 present), running
  `tests/unit/lint-adr-enforced-by-test.sh` produces 2 failures:
  `[A7] the real tree passes` (lint fails because ADR-005 has `## Enforced by` but is
  still in the baseline) and `[#1764/DSADR-7] ADR-005… must be removed from the
  baseline`. Both fire correctly. The finding was opened against an earlier version of
  the test file.

- **issue-acceptance finding 1 (RQCLA-2 integration gap)**: not mine — the DSCLA-2
  SPEC says "When: rsc_render_header is called with the run id and holder string". My
  test correctly calls `rsc_render_header` in-process with `_ZBUILD_CLAIM_HOLDER` set
  and asserts the output format. The gap (sidecar spawned before `_ZBUILD_CLAIM_HOLDER`
  is set in `runner.sh`) is a code-stage defect in `core/pipeline/runner.sh`, not a
  test-author gap.

## Full SPEC coverage

- DSCLA-1: unit test (gh called with zbuild:claimed, no hostname)
           + teardown [DSCLA-1] (claim present when first stage ran)
- DSCLA-2: unit test (rsc_render_header with `run_id=X machine=H` → full comment format)
- DSCLA-12: unit test (CI URL in `<!-- zbuild-holder: CI_URL -->` with closing `-->`)
- DSCLA-3: unit test + teardown (non-zero exit, no stage, pipeline.refused.claimed event)
- DSCLA-5: teardown (zbuild:claimed absent after normal completion)
- DSCLA-6: teardown (zbuild:claimed absent after failure)
- DSCLA-7: teardown (zbuild:claimed absent after TERM)
- DSCLA-8: unit test (zbuild_claim_acquire "" → 0, no gh calls)
- DSCLA-9: teardown (holder in output, non-zero exit, no stage dispatched)
- DSCLA-10: unit test (pipeline.refused.claimed in config/event-schema.json)
- DSCLA-11: teardown (non-running status on all exit paths)
- DSADR-7: lint-adr-enforced-by-test.sh (ADR-005 has `## Enforced by`, not in baseline)

## Test files

- `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-8, DSCLA-10, DSCLA-12
- `tests/integration/teardown-repeat-signal-test.sh`
  DSCLA-1, DSCLA-3, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9, DSCLA-11
- `tests/unit/lint-adr-enforced-by-test.sh`
  [#1764/DSADR-7]
