# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE (pass 5)

## Changes in pass 5

### 1. `tests/integration/teardown-repeat-signal-test.sh`
- Fixed `[DSCLA-1/5]` split-tag → `[DSCLA-1]` (findings 6, 7, 8).
  The assertion "zbuild:claimed was present before the first stage dispatched" is a
  DSCLA-1 assertion only (claim added before first stage dispatch). DSCLA-5 release
  is proven by the separate assertion immediately below.
- Added DSCLA-11 signal exit path test (finding 5):
  Given: events.jsonl with pipeline.start only (no terminal event, as on TERM).
  When: rendered with "interrupted" override (what the sidecar does on TERM).
  Then: status header is not "running".
  Passes on both old and new code (DSCLA-11 is [done]).

### 2. `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
- Added `<!-- zbuild-holder: -->` render assertion for DSCLA-2 (finding 2):
  After zbuild_claim_acquire sets _ZBUILD_CLAIM_HOLDER, sources run-status-render.sh,
  creates a minimal events.jsonl with pipeline.start, renders via rsc_rows_json +
  rsc_render_header, checks the header contains `<!-- zbuild-holder: run-dscla2-123`.
  FAILS on base code (rsc_render_header doesn't output <!-- zbuild-holder: -->).
  PASSES on new code (which adds the holder embedding to rsc_render_header).

## Answers to open findings

- finding 1 (DSCLA-1 "no stage dispatched" missing from unit test):
  DONE — fixing [DSCLA-1/5] → [DSCLA-1] in the teardown test makes the [DSCLA-1]
  assertion appear. That assertion ("zbuild:claimed was present before the first
  stage dispatched") proves the claim was added before the stage ran, which is
  exactly "no stage dispatched before claim". The teardown test starts a full
  runner, so the stage dispatch is real.

- finding 2 (DSCLA-2 missing <!-- zbuild-holder: --> assertion):
  DONE — added render assertion to claim-coordinator-unit-test.sh.

- finding 3 (DSCLA-8 Given/When should be a runner start):
  WRONG — a runner-based test for DSCLA-8 would PASS on base code too (the base
  runner also makes no claim for goal-only runs — it never calls the coordinator
  at all). The direct zbuild_claim_acquire "" call is the only approach that fails
  on base code (function doesn't exist on base code) and passes on new code.

- finding 4 (DSCLA-10 Given/When should set up zbuild:claimed and run the runner):
  WRONG — the Then clause for DSCLA-10 is "the event-schema emitted-coverage check
  does not fail on pipeline.refused.claimed as an unregistered event." The only
  assertable thing is whether pipeline.refused.claimed appears in config/event-schema.json.
  The Given/When in the SPEC describe the motivating scenario, but the test for
  the Then clause is correctly a grep of the schema file. It FAILS on base code
  (not in schema) and PASSES on new code (added to schema).

- finding 5 (DSCLA-11 signal exit path not covered):
  DONE — added the signal path case to the DSCLA-11 section.

- finding 6 (DSCLA-1 no [DSCLA-1] tag in teardown test):
  DONE — fixed by changing [DSCLA-1/5] → [DSCLA-1].

- finding 7, 8 ([DSCLA-1/5] is not a valid tag):
  DONE — changed to [DSCLA-1].

## Verified SPEC coverage

All SPECs covered:
- DSCLA-1: unit test (zbuild_claim_acquire → 0, zbuild:claimed in store, no hostname)
           + teardown [DSCLA-1] (claim present when first stage ran = added before dispatch)
- DSCLA-2: unit test (no gh comment, _ZBUILD_CLAIM_HOLDER set with run_id + machine,
           CI sub-case with URL, <!-- zbuild-holder: --> in render output, no hostname suffix)
- DSCLA-3: unit test (zbuild_claim_acquire → 1) + teardown (non-zero exit, no stage,
           pipeline.refused.claimed event) — all [DSCLA-3]
- DSCLA-5: teardown (zbuild:claimed absent after normal completion) [DSCLA-5]
- DSCLA-6: teardown (zbuild:claimed absent after failure) [DSCLA-6]
- DSCLA-7: teardown (zbuild:claimed absent after TERM) [DSCLA-7]
- DSCLA-8: unit test (zbuild_claim_acquire "" → 0, no gh calls) [DSCLA-8]
- DSCLA-9: teardown (holder in output, non-zero exit, no stage dispatched) [DSCLA-9]
- DSCLA-10: unit test (pipeline.refused.claimed in config/event-schema.json) [DSCLA-10]
- DSCLA-11: teardown (normal exit, failure exit, TERM signal — all show non-running) [DSCLA-11]

## Open issues (not mine)

- `tests/unit/event-schema-emitted-coverage-test.sh` fails because `pipeline.refused.claimed`
  is not yet in `config/event-schema.json`. This is an implementation file I cannot touch.
  My DSCLA-10 test asserts its presence and correctly fails on base code. The fix belongs
  to the code stage.

- `issue-acceptance finding 1`: pipeline.refused.claimed not in config/event-schema.json —
  not mine (config/event-schema.json is an implementation file outside test folders).

## Interface assumptions for new code

New function `zbuild_claim_acquire <issue>`:
- Returns 0 (success): writes `zbuild:claimed` to labels.txt; sets `_ZBUILD_CLAIM_HOLDER`
- Returns 1 (already claimed): reads holder from run-status-comment.txt (local-fs) or
  gh API (gh backend), extracting `<!-- zbuild-holder: VALUE -->` field; sets `_ZBUILD_CLAIM_HOLDER`
- Returns 0 (early exit): when issue argument is empty

Runner.sh (new code):
- Calls zbuild_claim_acquire after admission lock, before first stage dispatch
- On return 1: emits `pipeline.refused.claimed` event, outputs holder string, exits non-zero
- In EXIT trap: calls coordinator release hook to remove zbuild:claimed

run-status-render.sh (new code):
- rsc_render_header reads `_ZBUILD_CLAIM_HOLDER` from env and outputs
  `<!-- zbuild-holder: VALUE -->` in the comment header when non-empty
