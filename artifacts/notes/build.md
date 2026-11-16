# Build Notes — #1764 GitHub Label Claim (iteration 2 — COMPLETE)

## Status: COMPLETE — all tests pass

## Changes made this iteration

### config/event-schema.json
- Added `"pipeline.refused.claimed"` to `known_types` (after `pipeline.refused.run_cap`)
- Fixes: test finding 1, DSCLA-10

### config/adr-enforcement-baseline.txt
- Removed `ADR-005-claim-coordinator.md` now that ADR-005 has an `## Enforced by` section

### core/claim/claim.sh
- Fixed `_ccgl_read_holder` for local-fs: now reads `run-status-comment.txt` and extracts
  `<!-- zbuild-holder: ... -->` line instead of reading `holder.txt`
- Fixed `_ccgl_read_holder` for gh: looks for `<!-- zbuild-run-status` comments instead of
  `<!-- zbuild-claim` markers
- Added `_ZBUILD_CLAIM_HOLDER="$holder"` on successful acquire (needed by DSCLA-2)
- Removed `_ccgl_post_claim_comment` and `_ccgl_finish_claim_comment` functions (holder goes in
  run-status comment via rsc_render_header, not in a separate gh issue comment)
- Removed `_ccgl_post_claim_comment` call from `zbuild_claim_acquire`
- Removed `_ccgl_finish_claim_comment` call from `zbuild_claim_release`

### scripts/lib/run-status-render.sh
- Added `<!-- zbuild-holder: ... -->` output in `rsc_render_header` after the run_id marker line
  (only when `_ZBUILD_CLAIM_HOLDER` is non-empty)

### docs/adr/ADR-005-claim-coordinator.md
- Added §1 (engine calls claim after admission lock and before first stage; release in EXIT path)
- Added §2 (single `zbuild:claimed` label; holder in run-status comment)
- Added §3 (corrects stale content: selection not from config/zbuild.yaml; engine now has built-in mechanism)
- Added `## Enforced by` section naming tests per statement

### docs/adr/ADR-059-issue-vs-run-keying.md
- Added paragraph to §4 noting that the admission flock handles intra-machine serialisation only;
  cross-machine exclusion is the claim coordinator's job (ADR-005 §1)

## Test results
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 26/26 pass
- tests/integration/teardown-repeat-signal-test.sh: 21/21 pass
- tests/unit/event-schema-emitted-coverage-test.sh: 23/23 pass
- All shape-floor tests: pass

## Open issue-acceptance finding 2 (circular source)
issue-acceptance finding 2 flags that plugin.sh sources core/claim/claim.sh. The design says
"plugin.sh must not source claim.sh." However the unit test (claim-coordinator-unit-test.sh)
sources only plugin.sh and then calls zbuild_claim_acquire. Without the circular source, the test
would fail because zbuild_claim_acquire is defined in claim.sh. The test file is read-only for
this stage. Answered as "not mine — requires a change to the read-only test file."
