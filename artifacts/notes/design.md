# Design Notes — Issue #1760 (updated by design-judge pass)

## What I read

### ADR-027 §5
The supported op set for `exit_when`/`abort_when`/`until` predicates is:
`eq | neq | gt | gte | lt | lte | contains | matches`

### Current state (mismatches with ADR-027):

**template.sh `_tpl_validate_cycles`** (lines ~1210-1213):
- Multi-condition exit_when validates `eq|ne|in` → should be full 8-op set
- Single-condition until: validates only `until.stage` membership, NO op validation
- AW| handler (lines ~509-523): no op validation for abort_when

**cycle-orchestrator.sh `_cycle_load_template`** (lines ~383-430):
- Multi-condition exit_when: validates `eq|ne` → should be 8 ops
- Single-condition until: validates `eq|ne` → should be 8 ops
- abort_when: NO op validation at all

**cycle-orchestrator.sh evaluators** (all three):
- `_cycle_eval_one_condition` (multi-condition): `eq|ne|in`, no `*)`
- `_cycle_check_until` (single-condition): `eq|ne|in`, no `*)`
- `_cycle_check_abort_when`: `eq|ne|in`, no `*)`

All three places: `ne` should become `neq`, `in` should be removed, and
`gt|gte|lt|lte|contains|matches` need to be added.

### Key facts:
- `neq` = rename from `ne`
- `in` = removed (refuse at load)
- New ops: `gt|gte|lt|lte|contains|matches`
- Every evaluator case statement needs `*)` that emits error and returns 1

### ADR-027 "Enforced by" section:
- ADR-027 is in the enforcement baseline (config/adr-enforcement-baseline.txt)
- The plan calls for adding an `## Enforced by` section and removing ADR-027 from the baseline

### Existing tests that pin op values:

**tests/unit/template-loader-recursive-flow-test.sh**:
- T6: asserts `op=eq` (that's fine, eq stays valid)
- No tests for invalid ops at load time

**tests/integration/cycle-orchestrator-abort-when-test.sh**:
- T1-T6: uses `op: eq` throughout (eq stays valid)
- No tests for invalid ops or the full 8-op set

**tests/integration/cycle-abort-when-no-match-converges-test.sh**:
- Uses `op: eq` throughout — fine

**tests/unit/core-pipeline-cycle-events-test.sh**:
- Only checks event types, not op values

### Template.sh multi-condition exit_when validation (line 1211):
`eq|ne|in) : ;;` → changes to `eq|neq|gt|gte|lt|lte|contains|matches) : ;;`

The existing `*) error` line (1212) pins the old set in its error message.
Those lines need updating.

### Wiring:
The load-time validation is called from `load_template` → `_tpl_validate_cycles`.
The runtime evaluation is called in `cycle_orchestrator_run`.

## Final design written

Design document at: /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md

9 SPECs total: SPEC-1-3 load-time refusal, SPEC-4-6 evaluator correctness per evaluator, SPEC-7 numeric guard, SPEC-8 *) branch, SPEC-9 ADR update (no-code). WIRING: both template.sh (SPEC-1-3) and cycle-orchestrator.sh (SPEC-4-8).

## Decisions

1. **Load-time validation** goes in two places: `template.sh::_tpl_validate_cycles` (for EW multi-condition and single-condition until and abort_when AW|) and `cycle-orchestrator.sh::_cycle_load_template` (for both condition types and abort_when).

2. The `*) error` branch in each evaluator `case` emits an error and returns 1 (refuses evaluation — cycle can't converge).

3. `ne` → `neq` rename. `in` refused at load.

4. Numeric ops (`gt|gte|lt|lte`) need non-numeric operand guards (emits an error rather than silent false).

5. ADR-027 gets an `## Enforced by` section naming the test files. ADR-027 is removed from the enforcement baseline.

## Existing assertions that will change meaning

- `cycle-orchestrator-abort-when-test.sh` and `template-loader-recursive-flow-test.sh` use `op: eq` — that stays valid, so NONE of the existing assertions become wrong.
- The `op must be eq|ne` error messages in `cycle-orchestrator.sh` lines 386, 427 will change to name the 8-op set.
- The `op must be eq|ne|in` error message in `template.sh` line 1212 will change.

None of these changes break existing passing assertions (the tests don't assert on the error message text, only on success rc=0 for valid ops).

## Scope additions over plan seed

The plan seed includes the 4 test files + 2 source files + ADR-027 + enforcement baseline.

Additional files needed:
- `tests/unit/core-pipeline-template-cycles-test.sh` — may pin the `eq|ne` op set for single-condition until or multi-condition exit_when; needs checking.
- Search for `op.*must.*be\|eq.*ne\|ne.*eq` in tests/ to find any test asserting on old op error messages.

---

## Design-judge verdict

Read: ADR-027 §5 (eight ops: eq|neq|gt|gte|lt|lte|contains|matches), cycle-orchestrator.sh
(_cycle_load_template validates eq|ne only, abort_when has no load-time op validation,
evaluators handle only eq|ne|in with no *) branch), template-loader-recursive-flow-test.sh
(no op-validation tests), cycle-abort-when-no-match-converges-test.sh (no eight-op tests),
cycle-orchestrator-abort-when-test.sh (no eight-op tests), core-pipeline-cycle-events-test.sh
(no eight-op tests), config/adr-enforcement-baseline.txt (ADR-027 present, line 27).

Bug confirmed tripartite:
1. abort_when has NO op validation at template load.
2. All three evaluators only handle eq/ne/in; six of the eight ADR-027 ops are absent.
3. No *) fallback — unknown ops silently fall through, never matching.

SPEC coverage:
- SPEC-1: abort_when.op validated at load, error names loop/field/bad-op/valid-set → fixes main bug
- SPEC-2: single-condition until.op validated at load against full eight-op set
- SPEC-3: multi-condition exit_when op validated at load
- SPEC-4-6: all eight ops evaluated correctly in each of the three evaluators
- SPEC-7: gt/gte/lt/lte with non-numeric operand → error not silent false
- SPEC-8: *) branch returns 1 in each evaluator → closes silent-skip path
- SPEC-9: ADR-027 §5 gains Enforced by section; removed from baseline

All facets of R-1 are covered. VERDICT: covered.
