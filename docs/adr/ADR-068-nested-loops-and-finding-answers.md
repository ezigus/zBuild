# ADR-068 — Nested loops and finding answers: the engine never decides who owns a finding

**Status:** Accepted (2026-10-04)
**Issue:** #2271
**Supersedes:** ADR-045 (bounded typed backward-route), ADR-061 (fault-class vocabulary)
**Amends:** ADR-021, ADR-027, ADR-040, ADR-046, ADR-047, ADR-054 §4, ADR-055 (finding-owner amendment)
**Related:** ADR-063 §5 (every model-calling stage declares a save-as-you-go output), ADR-066, ADR-067

## Context

Findings went back to the wrong stage regularly. Stages do not know about each other, so the engine guessed who owned each finding:
- **Fault classes:** gates declared `specification` / `scope` / `implementation` (ADR-061), and the gate aggregator rolled them up.
- **`route_back`:** a template edge jumped from the build loop back to the design loop on a fault (ADR-045).
- **Ownership framing:** the summaries later stages read told each stage which findings were "yours to fix" (`finding-owner.sh`, ADR-055 amendment).
- **Escalation ladder:** the acceptance check reclassified a finding as design's from round 2 onwards.

Each misroute was fixed with another rule (#1777, #2157, #1847, #1846). In #2032 run 37066151065 a design-owned WIRING choice went to build and test-author, and test-author "fixed" it with a test that greps a file. Eric (2026-10-03): the routing logic is "much too complicated and wrong".

## Decision

1. **Nested loops, nothing jumps backwards.** The default flow is one outer loop holding the design loop and the build loop (`delivery_loop` in `simple.yaml` and `deployed.yaml`): design loop → impact → build loop. Plan runs once, before it. `route_back` is removed; a template that declares it is refused at load, with an error that says the nested loops replace it.
2. **Inner loops reset each time they start.** Each time the outer loop goes round, the design loop and the build loop start again at round 1. Budgets: outer 2, design 2, build 3, so at most 2 × (2 + 3) model rounds.
3. **An inner loop that ends without converging ends the outer round.** This applies when the inner loop declares `on_max: halt`, or runs out with tests failing. The members after it are skipped and the outer loop goes round from the top; a design the checks still reject is never built. When the outer rounds are spent, the outer loop's own `on_max` applies, and in the default flow the run stops. An inner loop with `on_max: continue` keeps ADR-019's fall-through.
4. **An outer loop's multi-condition `exit_when` is its own.** Running an inner loop never changes how the outer loop's exit is evaluated.
5. **Every check lists its findings as numbered items** (`data.findings: [{n, text}]`) in plain sentences (ADR-067). Identity comes from where a finding already lives: the stage's result, item n. Later stages see each finding on its own line: `- <stage> finding <n> (opened by <stage>): <text>`.
6. **Every stage answers every finding it receives, with a standard word:** `done — <what it changed>` or `nothing to do — <why>`. Answers are not exclusive: several stages may do work on the same finding, and another stage's `done` does not mean this stage has nothing to do. The answering stage is recorded with each answer. The router asks for the answers, in the one funnel every model call crosses, and records them per unit (`<state>/finding-answers/<unit>.json`). The stages that answer are exactly the stages that call a model: the stages that declare a save-as-you-go output (ADR-063 §5).
7. **Only the stage that opened a finding can close it,** with `satisfied — <why>`. A model check judges the work fresh first, then is shown its own earlier findings and asked about each. A check that does not call a model closes a finding by not reporting it again.
8. **The engine only counts answers; it never decides ownership.**
   - **`unowned: yield`** on a loop: when every member of the loop that answers findings (other than the finding's opener) answered `nothing to do` to the same finding, the loop ends early. The outer loop then goes round from the top, carrying every finding.
   - **`unowned: halt`** on the outer loop: when the stages in the next part of the loop also answer `nothing to do` to that finding, nobody owns it. The run stops and writes `artifacts/unowned-findings.md`, listing each finding, the stage that opened it, and every answer with its why.
   - One `done` from anyone keeps a finding where it is. A member that should have answered and did not counts as not disclaiming.
9. **No fault classes.** No stage writes a `fault`, the gate aggregator rolls none up, and rc 11 is retired from the engine's vocabulary (ADR-054 §4).

## Consequences

- The engine loses the fault vocabulary (`core/pipeline/fault.sh`), the ownership resolver (`core/pipeline/finding-owner.sh`), the `route_back` parser, validator and runner rewind, the cycle's early-rewind and fallback logic, and the acceptance check's iteration-numbered escalation.
- One new mechanism (`core/pipeline/unowned.sh`) counts answers. It names no stage (ADR-047).
- A stage now spends some of each prompt on the answer block. That is the price of letting each stage judge its own job instead of the engine guessing.
- A finding a stage misjudges as its own circles at most until the loop budgets run out. A finding nobody owns stops the run at once, with a report.

## Implementation Notes

- `core/pipeline/unowned.sh`: answer counting (`_unowned_yield_check`, `_unowned_halt_check`, the report).
- `scripts/lib/stage-answers.sh`: the answer request the router appends, and the parser the router records replies with (`answers_record` → `<state>/finding-answers/<unit>.json`).
- `scripts/lib/stage-summary.sh` `stage_findings_json`: every check writes `data.findings` through it.
- `core/pipeline/input-resolve.sh`: lists each finding with its opener and gives every reader one framing.
- `core/pipeline/cycle-orchestrator.sh`: the end-of-round rule for nested loops, `unowned: yield|halt`, and rc 5/9 passing straight up from an inner loop.
- `core/pipeline/template.sh`: the `unowned:` key (`UO` row), the `route_back` refusal, the flow-ordered stage list, and the loop validator over each loop's full expansion.
- An inner loop that is blocked (rc 5) or whose model call is unavailable or rate-limited (rc 9) stops the run rather than going round; going round would only repeat it.

## Enforced by

- §1 → `tests/unit/no-fault-routing-test.sh` R1 (a template with `route_back` is refused, and the error says what replaces it)
- §2, §3, §4 → `tests/integration/nested-loop-rounds-test.sh` L1–L6; `tests/integration/cycle-member-dispatch-events-test.sh` §3 (rc 8 still halts on the last outer round); `tests/integration/cycle-rate-limit-aborts-run-test.sh` (rc 9 from an inner loop ends the run)
- §5 → `tests/unit/numbered-findings-test.sh` N1–N5
- §6, §7 → `tests/unit/finding-answers-test.sh` A1–A6
- §8 → `tests/integration/unowned-finding-test.sh` U1–U4
- §9 → `tests/unit/no-fault-routing-test.sh` R2–R4; `tests/unit/dispatch-rc-test.sh` SPEC-5 (rc 11 retired)
