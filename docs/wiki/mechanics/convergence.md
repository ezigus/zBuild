The existing page is missing all three required section headings (`## How to use`, `## Reference`, `## Advanced`) and the `_Newcomers can skip this section._` sentinel. I'll generate a conforming replacement now.
# convergence

Convergence is the set of rules that tell a zBuild cycle when it is finished — what condition counts as "good enough to stop looping", and what to do if the cycle exhausts its attempts without ever reaching that condition. It matters because every cycle must be bounded and must resolve to a clear outcome so the pipeline can continue or halt cleanly.

## How to use

Add a `convergence:` block inside a `cycles:` entry in your template YAML. The minimal form names one stage whose verdict must equal `pass`:

```yaml
cycles:
  build_review_cycle:
    max_iterations: 3
    on_max: continue
    exit_when:
      stage: gate-aggregator
      field: verdict
      op: eq
      value: pass
    members:
      - build
      - review
      - gate-aggregator
```

For multi-condition exit, list conditions under `exit_when:` and set a combinator:

```yaml
    exit_when:
      combinator: all          # or: any
      conditions:
        - stage: gate-aggregator
          field: verdict
          op: eq
          value: pass
        - stage: review
          field: status
          op: eq
          value: complete
```

## Reference

**Defined in:** `core/pipeline/cycle-orchestrator.sh`

| Field | Type | Description |
|---|---|---|
| `exit_when.stage` | string | Member stage whose output is evaluated after each iteration. |
| `exit_when.field` | `verdict` \| `status` | The output field to inspect. |
| `exit_when.op` | `eq` \| `ne` | Comparison operator. |
| `exit_when.value` | string | Expected value; cycle exits when the comparison holds. |
| `exit_when.combinator` | `all` \| `any` | How multiple conditions are combined (omit for single-condition mode). |
| `exit_when.conditions[]` | list | Required when `combinator` is set; each entry has the same `stage/field/op/value` shape. |
| `max_iterations` | integer (1–10) | Hard upper bound on loop count. Cannot exceed the engine absolute ceiling of 10. |
| `on_max` | `continue` \| `halt` | Outcome when the bound is reached without converging. `continue` falls through to the next pipeline stage; `halt` stops the pipeline. |
| `plateau_window` | integer | Iterations of zero-progress before the engine emits `cycle.plateau`. Defaults to 3. |
| `divergence_window` | integer | Consecutive regressions before the engine emits `cycle.stalled`. Defaults to 2. |
| `velocity_plateau.window` | integer | Optional. Enables velocity-based stall detection (0 = disabled). |

**Return codes from `cycle_orchestrator_run`:**

| rc | Meaning |
|---|---|
| 0 | Converged — `exit_when` condition satisfied. |
| 1 | `max_iterations` reached without converging. |
| 2 | Plateau detected (no score progress). |
| 3 | Divergence detected. |
| 4 | Template config invalid (emits `cycle.config.invalid`). |
| 130 | Aborted by SIGINT/SIGTERM. |

**Key events emitted:**

- `cycle.predicate.evaluated` — fired after every `exit_when` check, recording the stage, field, operator, expected value, actual value, and whether it matched.
- `cycle.plateau` / `cycle.stalled` — operator-visible WARN banners when progress stalls.
- `cycle.aborted` — fired on signal before returning rc=130.

## Advanced

_Newcomers can skip this section._

**ADR-021** introduced the outer-cycle orchestrator (F1 framework); F2 (`#511`) wired cycles into `config/templates/standard.yaml`. The mechanic is flag-gated: the runner only enters the cycle branch when `ZBUILD_CYCLES_ENABLED=1` and a `cycles:` overlay is parsed.

**ADR-047 (`#1284`)** extended `exit_when` from a single predicate to a multi-condition block with an explicit `all`/`any` combinator. Omitting the combinator is byte-identical to the pre-ADR-047 single-condition behavior.

**Absolute ceiling:** `_CYCLE_ABSOLUTE_MAX=10` is hardcoded in the orchestrator and checked _before_ the template's `max_iterations` value. A template requesting more is clamped and emits `cycle.config.invalid`. This guard prevents runaway cycles from silent misconfiguration.

**Feedback wiring:** convergence interacts with the `feedback:` block in a cycle definition. After each iteration the orchestrator calls `_cycle_apply_feedback` to route outputs from one member stage into the input field of another (resolved via manifest-graph path lookup, not the legacy `artifacts/<stage>/<output>` layout). See `scripts/lib/manifest-graph.sh`.

**Parallel members:** a cycle member may be a `type: parallel` group (ADR-039, `#1132`). The orchestrator dispatches it through the parallel orchestrator; `exit_when` still evaluates after the group completes.

**Timeout escalation (ADR-029):** per-member consecutive router-timeout counters (`_CYCLE_TIMEOUT_RUN`) survive across iterations. On repeated timeouts the orchestrator bumps `max_turns` geometrically (G3), anchored to the first-timeout baseline (`_CYCLE_TURNS_BASE`). These counters are persisted by `cycle_id:stage_name` key so nested re-entry of the same cycle carries forward accumulated timeout budget.

See [[mechanics/cycle]], [[mechanics/gates]], [[mechanics/route_back]].
