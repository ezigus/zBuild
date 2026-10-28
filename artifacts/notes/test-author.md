# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 26

## Status: COMPLETE

All 6 SPECs have assertions written. Round-26 fix addresses awk `\b` portability bug.

## Round 26 fix

**Problem (test-stage feedback)**: The SPEC-6 assertion for `ADR-054 §11 content
describes the per-run limit` was failing with:
  `§11 body does not contain max_run_s/wall-clock/per-run — may describe an unrelated topic`

The §11 existence check (`grep -qE '§[[:space:]]*11\b'`) passed because GNU `grep -E`
supports `\b` as a word boundary extension. But the awk body-extraction command used the
same `\b`:

```
awk '/§[[:space:]]*11\b|###[[:space:]]+11\./{f=1;next} ...'
```

In **POSIX awk** (and mawk), `\b` inside a regex is a **backspace character** (0x08),
not a word boundary. So the awk pattern never matched any line, `_s11_body` was empty,
and the grep for `max_run_s` failed on an empty string.

ADR-054 in the worktree DOES contain §11 (the implementation is in place); the bug was
in the awk portability, not in the ADR or the existence check.

**Fix applied to `tests/unit/run-limit-precedence-test.sh`**:

Replaced `\b` in the awk pattern with `[^0-9]` (any non-digit character):
```
# Old (POSIX-awk broken — \b is backspace, not word boundary):
awk '/§[[:space:]]*11\b|###[[:space:]]+11\./{f=1;next} f&&/^##/{exit} f{print}'

# New (portable):
awk '/§[[:space:]]*11[^0-9]|###[[:space:]]+11\./{f=1;next} f&&/^##/{exit} f{print}'
```

- `[^0-9]` matches any non-digit: `:`, ` `, `—`, `*`, etc. (all the chars that follow
  `11` in the actual headings).
- Still correctly excludes `§110`, `§112`, etc. (digits would match `[0-9]`).
- Verified: no `§11` cross-references appear before line 509 in ADR-054, so the
  pattern fires exactly once on the correct amendment heading.

## Round 25 fix (retained for reference)

After the `§11 exists` if-block, added a new assertion block that:
1. Extracts the §11 body using awk: lines from after the §11 heading to the
   next `##` heading (any markdown heading level).
2. Checks the body contains at least one of: `max_run_s`, `wall.clock`,
   `per.run`, `run.level`, `run limit`.
3. Asserts pass/fail with label `[#1944/SPEC-6] ADR-054 §11 content describes
   the per-run limit`.

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 ✓
### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 ✓ (awk \b fix)
### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 ✓
### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 ✓
### tests/unit/run-open-items-test.sh — O9 updated to 6 ✓
### tests/unit/runner-signal-rearm-test.sh — [SPEC-5] awk pattern narrowed ✓

## Existing checks verified

1. run-open-items-test.sh [O9]: count is 6 ✓
2. runner-signal-rearm-test.sh [SPEC-5]: awk pattern uses `/trap '.*' TERM$/` ✓
