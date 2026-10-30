# Issue Acceptance Notes — #1753

## What I read
- map.sh lines 128–179: the new `[[ "$outcome" != pass ]] && flagged=yes` on line 157 (SPEC-1).
- runner.sh lines 3720–3749: new stop block at 3731–3742 checks ZBUILD_RUN_FLAGGED=yes before
  calling _update_stage_status (SPEC-4). Block position confirmed: precedes line 3743
  (_update_stage_status call).
- ADR-040 amendment at lines 459–484: amendment text covers all three required statements;
  Enforced by names both SPEC-1 and SPEC-4 tests; both files exist (modified in diff).
- pr-delivery/plugin.sh line 161: auto_unless_flagged only merges when
  `"${ZBUILD_RUN_FLAGGED:-}" == "no"` — explicit "no" required, unset and "yes" both
  block merge (SPEC-3, already done).
- engine-combines-map-test.sh: 10 distinct non-pass outcomes tested for SPEC-1.
- runner-map-parallel-stage-envelope-test.sh: three-form SPEC-4 test (static × 2, runtime × 1).

## Conclusions per requirement

**R-1 / Decision block (the single ISSUE REQUIREMENT)**

All four behavioral claims of the Decision are met:

1. "Lens that does not finish counts as a failure" — SPEC-1: `!= pass` → flagged=yes.
   Tests: 10 non-pass outcomes explicitly asserted (timed_out, out_of_turns, interrupted +
   unusable, throttled, rate_limited, unavailable, misconfigured, broken, fail). If reverted
   to `== fail`, 9 of 10 SPEC-1 sub-tests would fail. ✓

2. "Run stops (hard stop): no PR opened, nothing merges, lens not retried" — SPEC-4: stop
   block in runner.sh returns 1 before _update_stage_status, before pr-delivery dispatch.
   Runtime test (assertion c) would fail if block removed. R5 (no retry) is satisfied by
   the run terminating entirely. ✓

3. "Holds even if every other lens passed" — SPEC-1's sub-tests use 5-pass/1-non-pass
   configurations; flag is set. ✓

4. "Only when every lens finishes and passes may the run merge" — flagged=no only when
   all outcomes are pass; pr-delivery checks `== "no"` (explicit); SPEC-3 unchanged. ✓

**SPEC-2 (ADR amendment, no-code requirement)**
ADR-040 amendment text:
- States element not finishing counts against the group ✓
- States runner.sh stops at map dispatch arm when ZBUILD_RUN_FLAGGED=yes (#1753) ✓
- Enforced by names SPEC-1 (engine-combines-map-test.sh) and SPEC-4
  (runner-map-parallel-stage-envelope-test.sh) ✓
- Both test files exist (modified in diff) ✓
- Reverting SPEC-1 breaks 9/10 SPEC-1 assertions; reverting SPEC-4 breaks runtime assertion (c) ✓

Note: issue body's ADR section says to reference "ADR-069" inline, but the amendment does
not cite it. This is a cross-reference style point; the behavioral requirement stated in the
Decision section does not require it, and the behavior is otherwise fully specified.

**SPEC-3 (already done)** — verified: line 161 of pr-delivery plugin requires
`ZBUILD_RUN_FLAGGED == "no"` for auto-merge; unset and "yes" both block it. Claim is correct. ✓

**TEST VERDICT: pass (830 assertions, 0 failures)** — all in-scope tests ran and passed.

## Verdict
PASS. Every behavioral requirement in the Decision block is implemented and its tests
would catch a regression. No unmet or unsure items.
