[bug] loop conditions use ADR-027's eight ops, checked at template load — an unknown abort_when op silently never matches today

## Decision

**Follow ADR-027 §5 exactly.** A loop condition's `op` is one of `eq | neq | gt | gte | lt | lte | contains | matches`, all eight implemented, spelled as the ADR spells them.
- `ne` becomes `neq`.
- `in` is removed: it is not in the ADR, and no shipped template uses it.
- Every condition (`until`, `exit_when`, `abort_when`) is checked **when the template loads**, and an unknown op is refused there.

## What is wrong today

- `abort_when.op` is checked nowhere. `_tpl_validate_cycles` (`core/pipeline/template.sh`) doesn't look at it, and `_cycle_check_abort_when` (`core/pipeline/cycle-orchestrator.sh`) has no `*)` branch. A misspelled op silently never matches. The abort is a safety switch, so it fails open.
- The op lists disagree with each other:
  - `template.sh` accepts `eq|ne|in` for `exit_when`;
  - `_cycle_load_template` accepts only `eq|ne` for `exit_when` and `until`, and checks at loop start, not at load;
  - the evaluators implement `in`.

  So a template using `in` passes load and is then refused mid-run.
- ADR-027 §5 lists eight ops; the code implements three, one of them spelled differently (`ne`). `in` came from ADR-061, which ADR-068 superseded.
- Shipped templates use only `op: eq` (10 uses across `config/templates/`).

## ADR

- **ADR-027 §5** and its validator rule "predicate `op` is in the supported set". The code is brought to the ADR, not the other way round.
- ADR-027 is in `config/adr-enforcement-baseline.txt`. Add an amendment, dated with the PR, that states the op set is enforced at load and names its enforcing tests inline.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** For each of `until`, `exit_when` and `abort_when`, an op outside the eight fails **template load**. The message names the stage or loop, the field, the bad op, and the valid set.
- **R2.** Each of the eight ops evaluates correctly in each of the three fields:
  - `gt|gte|lt|lte` compare numbers, and a non-numeric operand is a load or evaluation error, never a silent false;
  - `contains` is a substring test;
  - `matches` is a bash extended regex.
- **R3.** `ne` and `in` are refused at load, with the same message as R1.
- **R4.** Every evaluator has a `*)` branch that refuses, so an op that somehow reaches evaluation can never silently not match.
- **R5.** `eq` behaves exactly as today. This is a guard; shipped templates load unchanged.

## Scope

- **Code:** `core/pipeline/template.sh` (`_tpl_validate_cycles`), `core/pipeline/cycle-orchestrator.sh` (`_cycle_load_template`, `_cycle_check_abort_when`, the `until`/`exit_when` evaluators).
- **ADR:** `docs/adr/ADR-027-recursive-flow-template-format.md`.
- **Tests that pin this behaviour:**
  - `tests/integration/cycle-orchestrator-abort-when-test.sh`
  - `tests/integration/cycle-abort-when-no-match-converges-test.sh`
  - `tests/unit/template-loader-recursive-flow-test.sh`
  - `tests/unit/core-pipeline-cycle-events-test.sh`

  Run `grep -rln "op: *ne\b\|op: *in\b\|\"ne\"\|\"in\"" tests/ config/ .zbuild/` and include every match.
- **Order:** shares `template.sh` with #1726. Don't run them in parallel.

## Additional context from issue comments

**Correction to the issue body — the scope of the gap is narrower than I wrote.**

I stated that `exit_when` / `until` get no load-time op checking. That is wrong for one of them. Verified line-by-line:

- `exit_when`'s **multi-condition (ADR-047 combinator) form IS validated** — `core/pipeline/template.sh:1271-1274`:
  ```bash
  case "$ew_o" in
      eq|ne) : ;;
      *) error "cycle '$cid': exit_when condition $ew_i: op must be eq|ne, got: $ew_o"; return 1 ;;
  esac
  ```
- The **single-condition `until` branch** (`template.sh:~1284-1300`) validates `until.stage` and its membership in the cycle's stages, but **not `until.op`**.
- **`abort_when` is not validated at all** — `grep -n abort_when core/pipeline/template.sh` shows it is only ever *parsed* (awk extraction at :499-506, :2019-2020, :2104-2113); it never appears in `_tpl_validate_cycles`.

So the accurate gap is: **`abort_when.op` and single-condition `until.op`** — not all four predicate kinds.

This makes the issue *sharper*, not weaker. `core/pipeline/template.sh:2433-2435` shows the authors already diagnosed exactly this class while fixing `route_back`:

> *"#1217 review fix (NIT): reject an unsupported predicate op at load — the orchestrator's route_back evaluator only implements eq/ne (**mirrors exit_when/abort_when**); any other op would silently never match."*

They named `abort_when` in the comment and then validated only `route_back`. The one predicate that fails **open** is the one that was left out, twice.

Acceptance criteria are unchanged in substance; scope them to `abort_when.op` and single-condition `until.op`, and treat `template.sh:2438-2442` as the pattern to copy.
