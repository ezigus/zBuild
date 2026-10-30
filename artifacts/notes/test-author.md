# test-author notes — issue #1760 (acceptance-check stage)

## Job: judge each SPEC pair (REQUIREMENT vs ASSERTION)

Reading the assertion text as provided in the prompt — this is the current state
of the tagged assertions, post any prior test-author work.

---

### SPEC-1

REQUIREMENT: abort_when.op outside the eight-op set is refused at template load
with an error naming the loop, field, bad op, AND valid set.

Assertions (>>):
1. rc=1 ✓
2. error contains "the_cycle" (loop) ✓
3. error contains "verdict" (field) ✓
4. error contains "contains_all" (bad op) ✓
5. valid-set check: `grep -qE 'eq|neq|gt|gte|lt|lte|contains|matches' <<< "$bad_aw_err"`

ISSUE with #5: The bad op is `contains_all`. Assertion #4 already ensures
`contains_all` appears in the error. `contains_all` contains `contains` as a
substring, so the regex `contains` in the grep alternation matches trivially on
the bad-op string — not on a separately listed valid set. This means #5 passes
whenever #4 passes, and does not actually verify that the valid op set is named.

VERDICT: partial — the loop/field/bad-op checks are sound; the valid-set check
is satisfied by the bad op's own name (contains_all ⊃ contains) and adds no
independent coverage.

---

### SPEC-2

REQUIREMENT: single-condition until.op outside the eight-op set is refused at
template load.

Assertions: rc=1, error names loop ("the_cycle"), error names bad op ("in").
The requirement is "refused at template load" — the rc=1 check establishes this
directly; the loop/op content checks are stricter than the requirement but
consistent with it.

VERDICT: corresponds

---

### SPEC-3

REQUIREMENT: multi-condition exit_when op outside the eight-op set is refused
at template load.

Assertions: rc=1, error names loop ("the_cycle"), error names bad op ("ne").
Same logic as SPEC-2. "ne" is not in the eight-op set (neq is). rc=1 establishes
refusal; error-content checks are consistent.

VERDICT: corresponds

---

### SPEC-4

REQUIREMENT: the full eight-op set evaluates correctly in the exit_when
single-condition evaluator (_cycle_check_until).

Assertions cover all 8 ops (eq, neq, gt, gte, lt, lte, contains, matches) with
both a match case (rc=0) and a no-match case (rc=1) for each.

VERDICT: corresponds

---

### SPEC-5

REQUIREMENT: the full eight-op set evaluates correctly in the exit_when
multi-condition evaluator (_cycle_eval_one_condition).

Assertions cover all 8 ops (eq, neq, gt, gte, lt, lte, contains, matches) via
the multi-condition variable layout + _cycle_load_template path, match and
no-match for each.

VERDICT: corresponds

---

### SPEC-6

REQUIREMENT: the full eight-op set evaluates correctly in the abort_when
evaluator (_cycle_check_abort_when).

Assertions cover all 8 ops (eq, neq, gt, gte, lt, lte, contains, matches) in
_cycle_check_abort_when, match (rc=0 = abort triggered) and no-match (rc=1)
for each.

VERDICT: corresponds

---

### SPEC-7

REQUIREMENT: gt/gte/lt/lte with a non-numeric operand emits an error (not
silent false) in each evaluator.

Assertions loop over {gt,gte,lt,lte} for all three evaluators:
- _cycle_check_until (single-condition): rc=1 + non-empty output
- multi-condition path (via _cycle_load_template): rc=1 + non-empty output
- _cycle_check_abort_when: rc=1 + non-empty output
Both conditions (error code AND error output) are checked for each evaluator/op.

VERDICT: corresponds

---

### SPEC-8

REQUIREMENT: each evaluator's *) branch returns 1 on an unrecognized op rather
than silently skipping.

Assertions: bogus_op submitted to all three evaluators, each expected rc=1.
The requirement is exactly "returns 1" — the assertions check rc=1.

VERDICT: corresponds

---

### SPEC-9

REQUIREMENT: ADR-027 §5 gains an ## Enforced by section naming the test files
that enforce the eight-op set; ADR-027 is removed from
config/adr-enforcement-baseline.txt.

Assertions:
1. ADR-027 has `## Enforced by` section
2. Section (extracted via awk to next ##) contains all 4 named test files
3. adr-enforcement-baseline.txt does NOT contain ADR-027

All three parts of the requirement are covered. The requirement says "§5" but
ADR convention has one ## Enforced by section covering the file; the assertion
correctly checks content rather than section numbering.

VERDICT: corresponds

---

## Summary table

| SPEC   | Verdict    |
|--------|------------|
| SPEC-1 | partial    |
| SPEC-2 | corresponds|
| SPEC-3 | corresponds|
| SPEC-4 | corresponds|
| SPEC-5 | corresponds|
| SPEC-6 | corresponds|
| SPEC-7 | corresponds|
| SPEC-8 | corresponds|
| SPEC-9 | corresponds|
