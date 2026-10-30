# Design — Issue #1760: Fix loop condition op validation to ADR-027's eight ops

## Architectural decision summary

**Goal.** Validate `abort_when.op`, single-condition `until.op`, and every
condition's `op` in multi-condition `exit_when` at template load against the
eight-op set ADR-027 §5 specifies — `eq | neq | gt | gte | lt | lte | contains |
matches` — and implement all eight in every runtime evaluator with a refusing `*)`
branch.

**Context.** ADR-027 §5 declared the supported op set in June 2026. The engine
was partially updated: `ne` (wrong spelling) and `in` (not in ADR-027) appear in
the evaluators and load-time checks; `gt/gte/lt/lte/contains/matches` are absent.
The bug: `abort_when` has no load-time op check at all in `template.sh`, so an
unknown op silently never fires. The evaluators' missing `*)` branch means a
typo evaluates as "never matches" — the cycle runs to max_iterations with no
indication of why the predicate never fires.

**Decision.**
- **template.sh `_tpl_validate_cycles`**: add op validation for abort_when (read
  from the AW| side-channel vars already populated); add op validation for
  single-condition `until.op` (currently missing); widen multi-condition
  exit_when from `eq|ne|in` to the full eight-op set. Each check emits an error
  naming the loop, the field, the bad op, and the valid set, then returns 1.
- **cycle-orchestrator.sh `_cycle_load_template`**: widen multi-condition
  exit_when check from `eq|ne` to the eight-op set; widen single-condition until
  check from `eq|ne` to the eight-op set; add abort_when op check (currently
  absent).
- **cycle-orchestrator.sh evaluators** (`_cycle_eval_one_condition`,
  `_cycle_check_until`, `_cycle_check_abort_when`): rename `ne` to `neq`;
  remove `in`; add `gt|gte|lt|lte|contains|matches` with numeric guards on the
  numeric ops; add a `*)` branch that emits an error and returns 1.
- **ADR-027**: add `## Enforced by` section naming the enforcement tests;
  remove ADR-027 from `config/adr-enforcement-baseline.txt`.

No new public surface is introduced. All changes are confined to two existing
engine files. The valid op `eq` is unchanged everywhere; all existing templates
and tests use only `eq` and are unaffected.

```scope
core/pipeline/template.sh
core/pipeline/cycle-orchestrator.sh
docs/adr/ADR-027-recursive-flow-template-format.md
config/adr-enforcement-baseline.txt
tests/unit/template-loader-recursive-flow-test.sh
tests/integration/cycle-orchestrator-abort-when-test.sh
tests/integration/cycle-abort-when-no-match-converges-test.sh
tests/unit/core-pipeline-cycle-events-test.sh
```

```acceptance
SPEC-1[code]: abort_when.op outside the eight-op set is refused at template load with an error naming the loop, field, bad op, and valid set covers: R-1
SPEC-2[code]: single-condition until.op outside the eight-op set is refused at template load covers: R-1
SPEC-3[code]: multi-condition exit_when op outside the eight-op set is refused at template load covers: R-1
SPEC-4[code]: the full eight-op set evaluates correctly in the exit_when single-condition evaluator (_cycle_check_until) covers: R-1
SPEC-5[code]: the full eight-op set evaluates correctly in the exit_when multi-condition evaluator (_cycle_eval_one_condition) covers: R-1
SPEC-6[code]: the full eight-op set evaluates correctly in the abort_when evaluator (_cycle_check_abort_when) covers: R-1
SPEC-7[code]: gt/gte/lt/lte with a non-numeric operand emits an error (not silent false) in each evaluator covers: R-1
SPEC-8[code]: each evaluator's *) branch returns 1 on an unrecognized op rather than silently skipping covers: R-1
SPEC-9[no-code]: ADR-027 §5 gains an ## Enforced by section naming the test files that enforce the eight-op set; ADR-027 is removed from config/adr-enforcement-baseline.txt covers: R-1
WIRING:
core/pipeline/template.sh
core/pipeline/cycle-orchestrator.sh
TESTFILES:
SPEC-1: tests/unit/template-loader-recursive-flow-test.sh
SPEC-2: tests/unit/template-loader-recursive-flow-test.sh
SPEC-3: tests/unit/template-loader-recursive-flow-test.sh
SPEC-4: tests/integration/cycle-abort-when-no-match-converges-test.sh
SPEC-5: tests/integration/cycle-abort-when-no-match-converges-test.sh
SPEC-6: tests/integration/cycle-orchestrator-abort-when-test.sh
SPEC-7: tests/unit/core-pipeline-cycle-events-test.sh
SPEC-8: tests/unit/core-pipeline-cycle-events-test.sh
SPEC-9: tests/unit/template-loader-recursive-flow-test.sh
```

## Findings

**Plan scope is complete.** No files outside the seed scope pin the old op set.
Existing tests all use `op: eq` (remains valid); the golden files reference
`op=eq` (unchanged). `tests/unit/core-pipeline-template-cycles-test.sh` pins
`until.op=eq` (line 65) — `eq` stays valid, so that test is unaffected and does
not need to be in scope.

**`ne` and `in` are removed.** Neither spelling appears in any shipped template
(`config/templates/`). `ne` appears only in the evaluators and load-time checks
in the two engine files; `in` appears only in those evaluators (added via #1987,
never declared in ADR-027). No template or test fixture uses them.

**abort_when load-time op check is entirely new.** The AW| row handler in
`template.sh` stores the op into `_TPL_CYCLE_ABORT_WHEN_OP_<safe>` but
`_tpl_validate_cycles` never reads it for validation. The fix adds a check there
(after the exit_when/until validation block).

**cycle-orchestrator.sh `_cycle_load_template` has no abort_when op check.** The
`_cycle_load_template` function validates the abort_when stage membership
implicitly (through _CYCLE_STAGES) but does not validate the op field. Adding it
mirrors the exit_when pattern already in that function.

**No event-schema changes.** The reason tokens (`until_op_invalid`,
`exit_when_op_invalid`) are already in use; no new event types are needed. An
`abort_when_op_invalid` reason token is a natural addition but requires no schema
entry (the `cycle.config.invalid` event type is already registered).
