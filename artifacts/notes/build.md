# Build Notes — #1764 GitHub Label Claim

## Status: All design steps done; 1 test-author concern (unlabeled failing assertion)

## Changes made in this iteration (current build)

### docs/adr/ADR-005-claim-coordinator.md
- Added [DSCLA-22] to §1 bullet in ## Enforced by section:
  `[DSCLA-22] (stub claim hook called after admission lock and before first stage; release hook called in EXIT path)`
- DSCLA-22 is in `tests/integration/teardown-repeat-signal-test.sh` (not claim-coordinator-unit-test.sh
  as design step 7 says — that file has no DSCLA-22; the design made an error about which file)

## All changes (from all iterations)

### plugins/claim-coordinator/github-labels/plugin.sh
- Uses `zbuild:claimed` (not `claimed:<machine>`) in both claim and release
- Added `_ccgl_read_holder()` to extract holder from run-status comment
- `claim_coordinator_claim()` returns `{"acquired": false, "holder": "..."}` on conflict

### core/claim/claim.sh
- Sources `core/plugin-registry/registry.sh` via `$_ZBUILD_ROOT`
- `zbuild_claim_acquire()` uses `discover_plugins` + `plugin_hook_call`
- `zbuild_claim_release()` unsets `_ZBUILD_CLAIM_ACQUIRED` BEFORE calling release hook (idempotency)
- Empty issue: returns 0 immediately without calling any hooks

### scripts/lib/run-status-render.sh
- `rsc_render_header` adds `<!-- zbuild-holder: ... -->` when `_ZBUILD_CLAIM_HOLDER` is set

### core/pipeline/runner.sh
- Sources claim.sh at top (line 33)
- `zbuild_claim_build_holder` called before sidecar spawn (line 2434)
- `zbuild_claim_acquire` called after issue lock acquire (line 2518)
- Refusal: emits `pipeline.refused.claimed` event + `printf '%s\n'` for holder + return 1
- `zbuild_claim_release` in `_runner_abort_trap` after `trap '' INT TERM` (line 2765)
- `zbuild_claim_release` in both early-failure return paths (lines 2546-2548, 2565-2567)

### config/event-schema.json
- Has `pipeline.refused.claimed` (line 19)

### config/shape-change-paths.txt
- Has `core/claim/claim.sh`

### docs/adr/ADR-005-claim-coordinator.md
- §1 Enforced by: DSCLA-1/5/6/7/22 from teardown-repeat-signal-test.sh
- §1(c) Enforced by: DSCLA-3 (unit test), DSCLA-9 (teardown test)
- §2 Enforced by: DSCLA-1/2/12 from unit test

### docs/adr/ADR-059-issue-vs-run-keying.md
- §4 Enforced by entry names [DSCLA-3]

### plugins/claim-coordinator/github-labels/README.md
- Describes `zbuild:claimed`, no `claimed:<machine>` references, ZBUILD_CLAIM_MACHINE_ID
  note says "holder string only, not label name"

## Test results

### teardown-repeat-signal-test.sh: 29/29 PASS ✓
### lint-adr-enforced-by-test.sh: 29/29 PASS ✓
### claim-coordinator-unit-test.sh: 35/36 — 1 unlabeled assertion fails

## Failing test (test-author concern, not mine)

Line 45-49 of claim-coordinator-unit-test.sh:
```bash
# ── label contains claimed:<machine> pattern ─────────────────────────────────
if grep -q "claimed:" "$labels_file" 2>/dev/null; then
    assert_pass "claimed label contains 'claimed:' prefix"
else
    assert_fail "claimed label contains 'claimed:' prefix" "..."
fi
```

The labels file contains `zbuild:claimed`. The grep for `claimed:` does NOT match `zbuild:claimed`
(colon precedes `claimed`, not follows it). This assertion pins the OLD `claimed:<machine>` behavior.
It has no DSCLA-* tag. The test cannot pass with correct code. The test-author stage must update:
- line 44 comment: change to describe the new label format
- line 45: change `grep -q "claimed:"` to `grep -qF "zbuild:claimed"`

## Open findings and disposition

1. acceptance-gate-code finding 1: "add a test that fails without the change to config/shape-change-paths.txt"
   - File is correct (has `core/claim/claim.sh`)
   - Cannot add tests in test folders (test-author territory)
   - Answer: not mine — test-author must add the test

2. lens-sre-code finding 1: "DSCLA-9 fixture is hand-written"
   - Lines 379-381 of teardown-repeat-signal-test.sh call `rsc_render_header` to generate it
   - The finding is stale/wrong
   - Answer: wrong — fixture uses rsc_render_header, not hand-written
