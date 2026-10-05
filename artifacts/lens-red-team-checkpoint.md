# Red-team checkpoint — #2032

## Files read so far
- cycle-orchestrator.sh:2555–2650: confirms converged=1 from _cycle_check_until is inverted (0=converge, 1=suppress). New block at 2588 fires when converged==0 AND _iter_did_not_finish==1. Placed correctly after build-unfinished block. converged==0 guard prevents double-fire.
- spec-correspondence/plugin.sh:240–344: `_sc_rc_file` is shared across batch call + all individual fallback calls. The LAST call's rc overwrites the file. If batch times out (rc=124) but any individual fallback succeeds (rc=0), the final `_sc_router_rc=0` and `_sc_disposition="complete"` — masking the batch failure.

## Key findings so far

1. **spec-correspondence rc-file overwrite (logic)**: Same `_sc_rc_file` is passed to BOTH the batch call (line 253) AND each individual fallback call (line 273). The final rc read after the loop is from the last call, not the worst call. If the batch fails (rc=124) but one individual fallback succeeds (rc=0), the final disposition is "complete", masking the batch timeout. This was INTRODUCED by this change. The test only covers all-calls-fail scenario.

2. **mktemp failure fallback**: If mktemp fails in spec-coverage, `_scv_rc_file=""`, and `printf '%s' "$?" > ""` is suppressed by `|| true` but the redirect error is printed to stderr. Minor but introduced.

## Conclusions
- No privilege escalation or injection vectors found (all inputs are engine-trusted)
- The converged==0 guard in cycle-orchestrator is correct
- The max_iterations path via SPEC-6 logic is consistent with the test passing
- Main concern: rc file overwrite semantics in spec-correspondence

## What next if stopped
- Read review-report plugin to check _rr_first_failed_rc logic for off-by-one or similar
- Verify _iter_did_not_finish computation at 2575-2582 to confirm it covers ALL members not just build
