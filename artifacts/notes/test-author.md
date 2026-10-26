# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 9

## Round 9 work

**Only outstanding issue from round 2 finding:** SPEC-2's message-content check was
checking for generic patterns (like "misconfigured") but not verifying that the output
NAMES the misconfigured source.

The SPEC says: "a message naming the misconfigured source". This means:
- For the env source: `ZBUILD_MAX_RUN_S` must appear in the message
- For the template source: `max_run_s` (the YAML field name) must appear

### Changes made to tests/unit/run-limit-precedence-test.sh

1. **Env case message-content check (lines 226–246)**: Replaced the `if/else` that
   only checked disposition OR stderr with a pattern that:
   - Checks `disposition=misconfigured` when state file exists (kept)
   - Collects output from `state.reason`/`state.message` or falls back to stderr+stdout
   - Asserts `ZBUILD_MAX_RUN_S` appears in the output (new)
   - Tag: `[#1944/SPEC-2]`

2. **Template case message-content check (new, lines 304–319)**: Added after the
   existing template rc=1 and stage-marker checks:
   - Collects output from `state.reason`/`state.message` or falls back to stderr+stdout
   - Asserts `max_run_s` appears in the output (new)
   - Tag: `[#1944/SPEC-2]`

Both new assertions are falsifiable: if the implementation does not include the source
name in the error message, the assertion fails.

### Verified

- `bash -n tests/unit/run-limit-precedence-test.sh` → SYNTAX OK
- `bash scripts/lib/lint-test-errexit.sh` → clean
- No sigpipe issues: all grep calls use herestrings (`<<< "$var"`) or file arguments

## All files — current state

### run-limit-precedence-test.sh — assertions
- SPEC-2: _runner_resolve_run_limit_s defined, precedence unit tests (template>env>20700)
- SPEC-2: non-integer/non-positive → rc=1 for both template and env
- SPEC-2: template_max_run_s() from real template.sh (falsifiable: reverted template.sh → assert_fail)
- SPEC-2: full runner test with invalid ZBUILD_MAX_RUN_S (env) → rc=1, stage not reached, ZBUILD_MAX_RUN_S named in message
- SPEC-2: full runner test with invalid template max_run_s → rc=1, stage not reached, max_run_s named in message
- SPEC-5: no platform-specific env vars in stage-limits.sh or runner.sh
- SPEC-6: ADR-025 word vocabulary includes timed_out; ## Enforced by cites new tests
- SPEC-6: ADR-054 §11 exists; ## Enforced by cites run-limit tests
- SPEC-6: adr-enforcement-baseline.txt does not list ADR-054-stage-contract.md
- SPEC-6: run_end_words timed_out describes wall-clock limit
- SPEC-6: lint-adr-enforced-by passes
- SPEC-6: lint-test-errexit passes

### run-watchdog-clean-exit-test.sh — no changes needed
- SPEC-3: all 4 assertions present and correct

### run-open-items-test.sh — no changes needed
- [O9]: 6 loop-ending lines (already updated from 5→6 in prior round)
- [O3]: run_end_words timed_out describes wall-clock limit

### run-timed-out-test.sh — no changes needed
- SPEC-1 P1-P4: all assertions present and correct (P4 has both RELEASE+PERSIST markers)

### resume-after-run-timeout-test.sh — no changes needed
- SPEC-4 P1-P4: all assertions present and correct

## Lint: CLEAN
- lint-test-errexit: clean (no mid-file set -e)
- All 4 test files: SYNTAX OK

## LOOP_COMPLETE
