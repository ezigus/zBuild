# Test Author Notes — Issue #1801

## Status: COMPLETE (round 8)

## Round-8 fixes applied

### 1. stage-timeout-process-group-test.sh — SPEC-2: negative-only check replaced with positive check

Checker finding (round 2): "'exits with status 1 when externally TERMed' is checked
only negatively (absence of exit 143) — a TERM trap exiting with status 2 or omitting
an exit entirely would still pass."

Root cause: The assertion at lines 158-165 (round 7) used:
  `grep 'exit 143' → if non-empty → assert_fail`
This passes if the trap has no exit or exits with 2 — neither of those contain "exit 143".

Fix: Replaced with a POSITIVE check using awk that:
- Tracks entry into each trap block (resets per trap so EXIT trap exit 1 is not counted)
- Looks for `exit 1[^0-9]` or `exit 1$` within the block that terminates with ` TERM`
- `found=1` only if the specific TERM trap body contains exit 1

NEGCTL coverage for positive check:
- pre-change (no trap): found=0 → assert_fail ✓
- post-change with exit 143: `/exit 1[^0-9]/ || /exit 1$/` doesn't match "exit 143" → found=0 → assert_fail ✓
- post-change with exit 2: same, no match → assert_fail ✓
- post-change with exit 1: matches → found=1 → assert_pass ✓

### 2. stage-timeout-dispatch-test.sh — SPEC-10: explicit negative check tagged

Checker finding (round 2): "For plugin_hook_call it only checks that zbuild_pg_kill
"$_lc_hook_pid" 1 is present, without an explicit negative check for any remaining
kill -KILL/-TERM in that function body, so both old and new code could coexist and
the assertion would still pass."

Root cause: The supplementary negative check at lines 209-219 (round 6) checked for
absence of `kill -TERM|kill -KILL` but was labeled without the [#1801/SPEC-10] tag
and commented as "not NEGCTL-distinguishing — confirms final state only."

Fix:
1. Added `[#1801/SPEC-10]` tag to both assert_fail and assert_pass labels
2. Changed comment to "EXPLICIT NEGATIVE CHECK" to make clear this is a required
   assertion, not a supplementary one
3. Changed `head -3` to `awk 'NR<=3'` in the error message to avoid SIGPIPE

How "both old and new code coexist" scenario is now caught:
- Primary assertion: zbuild_pg_kill "$_lc_hook_pid" 1 present → PASS
- [#1801/SPEC-10] negative: kill -TERM or kill -KILL still present → FAIL
→ The test fails, catching the incomplete migration.

## Round-7 fixes applied (carried forward)

### 1. stage-timeout-process-group-test.sh — SPEC-2: exit code was exit 143

Fix: Replaced positive check for exit 143 with negative check for absence of exit 143
(round 7, later replaced in round 8 with positive check for exit 1).

### 2. stage-timeout-precedence-test.sh — SPEC-3 isolation race condition

Root cause: fake sleep intercepted `sleep 1` (the hook), which exited immediately,
causing the watchdog to be killed before it could log "5400".

Fix: fake sleep delegates small values (< 100 s) to real sleep, only intercepts large
values (>= 100 s, i.e. the 5400 s watchdog timer).

## Round-6 fixes applied (carried forward)

### stage-timeout-precedence-test.sh — SPEC-3: source registry.sh

Root cause: subshell sourced lifecycle.sh directly; yaml_get/verify_plugin_for_source
were undefined causing early return before watchdog was armed.
Fix: source registry.sh (facade that sources everything in correct order).

### stage-timeout-dispatch-test.sh — SPEC-1: disposition=timed_out

Fix: targeted grep on plugin.run.timed_out block to verify disposition=timed_out field.

### stage-timeout-dispatch-test.sh — SPEC-10: grace-period=1

Fix: added assertion for `zbuild_pg_kill.*_lc_hook_pid.* 1`.

### orch-backend-misconfigured-test.sh — SPEC-19: install.sh mechanism

Fix: added assertion verifying rsync -a and `for d in scripts core plugins config`.

## Final SPEC coverage

SPEC-1:  stage-timeout-dispatch-test.sh ✓
SPEC-2:  stage-timeout-process-group-test.sh ✓ (round-8: positive exit 1 check)
SPEC-3:  stage-timeout-precedence-test.sh ✓ (round-7: race condition fixed)
SPEC-4:  stage-timeout-loader-validation-test.sh ✓
SPEC-5:  stage-timeout-retry-test.sh ✓
SPEC-6:  stage-timeout-always-run-test.sh ✓
SPEC-7:  stage-timeout-no-flat-limit-test.sh ✓
SPEC-8:  orch-sequential-retired-guard-test.sh ✓
SPEC-9:  orch-backend-misconfigured-test.sh ✓
SPEC-10: stage-timeout-dispatch-test.sh ✓ (round-8: [#1801/SPEC-10] tag on negative check)
         stage-timeout-always-run-test.sh ✓
SPEC-11: orch-sequential-retired-guard-test.sh ✓
SPEC-15: no testfile (grep search, no assertions to write)
SPEC-16: no testfile (npm test/lint pass — enforced by pipeline)
SPEC-17: covered mechanically by SPEC-8 no-orch-sequential grep ✓
SPEC-18: event-schema-emitted-coverage-test.sh ✓
SPEC-19: orch-backend-misconfigured-test.sh ✓

## Existing check update

runner-release-exit-paths-test.sh SPEC-6b ✓ (updated in round 6, verified)
