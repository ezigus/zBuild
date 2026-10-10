# Acceptance checkpoint — issue #1668

## What I've read so far
- Issue: remove impact from delivery_loop in simple.yaml and deployed.yaml
- TEST VERDICT: fail (2 failing tests)

## Failing tests
1. `tests/unit/impact-max-turns-test.sh` — 3 assertions fail (max_turns=45, timeout_s=600, max_turns>25). This test reads _TPL_STAGE_ROUTER_* variables from simple.yaml. After impact removed from simple.yaml, those variables are empty. The issue classified impact-*-test.sh as "verified not affected" but this test reads template config, not just plugin internals.

2. `tests/unit/template-always-run-test.sh` — SPEC-2 pin on flow count=20, now gets 19. This file not mentioned anywhere in the issue scope.

## Conclusions so far
- R-2 is unmet: impact's unit tests don't all pass; impact-max-turns-test.sh fails
- R-3 is met for the two specific files named (template-simple-yaml-test.sh and core-pipeline-cycle-build-test-wiring-test.sh)
- R-4 ADR-068 amendment looks correct in the diff; lint uncertain (failing tests are not lint tests but overall TEST VERDICT is fail)
- R-5 cannot be verified — test suite fails

## Still unresolved
- Whether PR body states the red step (not visible in diff)
- Whether lint specifically passes (failures are unit tests, not lint)

## Next steps if stopped
Write final verdict: FAIL, R-2 (impact-max-turns-test.sh fails) and R-5 (dogfood can't be confirmed with failing tests)

## Confirmed in this run
- impact-max-turns-test.sh line 22: calls `load_template simple.yaml` then `template_stage_router_max_turns impact` — directly reads template config, not plugin internals. Issue's "verified not affected" claim is wrong.
- template-always-run-test.sh line 63: hardcodes count=20; not in issue scope; fails because count dropped to 19.

## Final verdict: FAIL
- R-2 UNMET: impact-max-turns-test.sh (an impact-*-test.sh) fails after template change
- R-5 UNMET: test suite fails, dogfood unverifiable
- R-1 UNSURE: PR body "red step" not visible in diff
