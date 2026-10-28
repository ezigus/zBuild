# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 25

## Status: COMPLETE

All 6 SPECs have assertions written. Round-2 checker feedback addressed.

## Round 25 fix

**Problem (checker feedback)**: SPEC-6's assertion confirmed §11 exists in
ADR-054 (by pattern-matching the section marker) and that the Enforced-by
section cited the four test files, but never checked that §11's **content**
describes the per-run limit. A §11 about an unrelated topic would still pass.

**Fix applied to `tests/unit/run-limit-precedence-test.sh`**:

After the `§11 exists` if-block (line 391), added a new assertion block that:
1. Extracts the §11 body using awk: lines from after the §11 heading to the
   next `##` heading (any markdown heading level).
2. Checks the body contains at least one of: `max_run_s`, `wall.clock`,
   `per.run`, `run.level`, `run limit`.
3. Asserts pass/fail with label `[#1944/SPEC-6] ADR-054 §11 content describes
   the per-run limit`.

The awk command:
```
awk '/§[[:space:]]*11\b|###[[:space:]]+11\./{f=1;next} f&&/^##/{exit} f{print}'
```
- Activates (`f=1`) on the §11 heading, skipping that line (`next`)
- Exits on the next `##`-level markdown heading
- Prints all body lines between them

Uses `grep -qiE ... <<< "$_s11_body"` (here-string, approved pattern).

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 ✓
### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 ✓ (fixed §11 content)
### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 ✓
### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 ✓
### tests/unit/run-open-items-test.sh — O9 updated to 6 ✓
### tests/unit/runner-signal-rearm-test.sh — [SPEC-5] awk pattern narrowed ✓

## Existing checks verified

1. run-open-items-test.sh [O9]: count is 6 ✓
2. runner-signal-rearm-test.sh [SPEC-5]: awk pattern uses `/trap '.*' TERM$/` ✓

## LOOP_COMPLETE
