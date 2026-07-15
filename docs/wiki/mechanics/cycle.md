Looking at the existing wiki page against the template, it's missing the required `## How to use`, `## Reference`, and `## Advanced` sections. I'll generate a conforming page now.

# cycle

A cycle repeats a group of pipeline members — such as build, test, and gate stages — until an exit condition is met or a maximum iteration count is reached. It is the mechanism zBuild uses to converge work automatically: instead of failing on the first test run, the pipeline loops and retries until all gates pass (or the iteration ceiling is hit).

## How to use

Declare a `cycles:` block in your template YAML and reference it from the `flow:` sequence. The runner only enters cycle logic when `ZBUILD_CYCLES_ENABLED=1` is set and a `cycles:` overlay is parsed.

```yaml
cycles:
  build_test_cycle:
    members:
      - build
      - test
      - gate-aggregator
    max_iterations: 5
    on_max: halt
    exit_when:
      stage: gate-aggregator
      field: verdict
      op: eq
      value: pass
    feedback:
      - from_stage: test
        from_output: results
        to_stage: build
        to_field: prior_results
        required: true

flow:
  - build_test_cycle
  - deploy
```

The `design_verify_cycle` (design → design-gate) and `build_test_cycle` (build → test → gates → gate-aggregator) in `config/templates/simple.yaml` are the canonical examples.

## Reference

**Defined in:** `core/pipeline/cycle-orchestrator.sh`

**Public entry point:** `cycle_orchestrator_run <cycle_id> <state_dir> <state_file>`

**Exit codes:**

| rc | Meaning |
|----|---------|
| 0 | Converged — `exit_when` condition matched |
| 1 | `max_iterations` reached |
| 2 | Plateau detected — score stopped changing |
| 3 | Divergence detected — quality regressing |
| 4 | Config invalid — template error |
| 130 | Aborted — SIGINT or SIGTERM received |

**Key template fields:**

| Field | Type | Description |
|-------|------|-------------|
| `members` | list | Ordered list of stage IDs (or `type: parallel` groups) to repeat |
| `max_iterations` | int | Hard cap on loop count; clamped to engine ceiling (10) |
| `on_max` | `continue` \| `halt` | Behavior on hitting `max_iterations`: fall through or fail |
| `exit_when` | map | Predicate checked after each iteration — `stage`, `field` (`verdict`\|`status`), `op` (`eq`\|`ne`), `value` |
| `exit_when.combinator` | `all` \| `any` | For multi-condition exit (ADR-047); omit for single-condition mode |
| `feedback` | list | Wires an output from one member to an input of another across iterations |
| `feedback[].required` | bool | If `true`, a missing artifact is a cycle config error |
| `blocking` | bool (per member) | If `true`, a member failure halts the cycle immediately (ADR-013) |
| `plateau_window` | int | Iterations of unchanged score before plateau exit; default 3 |
| `divergence_window` | int | Consecutive regressions before divergence exit; default 2 |

**Globals set after `cycle_orchestrator_run` returns:**

- `_CYCLE_LAST_TERMINATED_REASON` — string enum (`converged`, `max_iterations`, `plateau`, `divergence`, `aborted`)
- `_CYCLE_LAST_ITERATIONS` — count of iterations executed
- `_CYCLE_LAST_HISTORY_FILE` — absolute path to the per-cycle iteration history log

## Advanced

_Newcomers can skip this section._

**ADR references:**
- ADR-021 — outer-cycle orchestrator design (F1 flag-gated stub; F2/#511 wires it into `simple.yaml`)
- ADR-025 — abort-propagation contract; the cycle installs its own INT/TERM traps and re-installs them after each member dispatch because `route.sh` clobbers them
- ADR-029 — router-timeout escalation (G2/G3): per-member consecutive timeout counters (`_CYCLE_TIMEOUT_RUN`) and max-turns base anchors (`_CYCLE_TURNS_BASE`) survive re-entry across iterations
- ADR-039 — a cycle member may be a `type: parallel` group; the cycle orchestrator dispatches it via `parallel-orchestrator.sh`
- ADR-045 — [[route_back]]: a later stage can re-enter a cycle (rc=11)
- ADR-047 — multi-condition `exit_when` with `combinator: all|any`; single-condition mode is byte-identical to the pre-ADR-047 behavior

**Engine ceiling:** `_CYCLE_ABSOLUTE_MAX=10`. Templates that request more than 10 iterations are clamped and a `cycle.config.invalid` event is emitted. This ceiling is checked before the template's own `max_iterations` value.

**Predicate instrumentation:** every `exit_when` evaluation emits a `cycle.predicate.evaluated` event (Wave 19-C-1 / #725) recording `stage`, `field`, `op`, `expected`, `actual`, and `match`. Every member dispatch emits `cycle.member.dispatch.start` and `cycle.member.dispatch.complete` (Wave 19-D-1 / #731). Query `events.jsonl` to forensically trace why a cycle terminated or why a member was never reached.

**Feedback path resolution:** output paths are resolved from the source stage's `manifest.yaml` `outputs[id==<X>].path` entry (F2 Pin 2 / #511) — the orchestrator does not assume any legacy `artifacts/<stage>/<output>` layout.

**Convergence detection** runs automatically when `plateau_window` or `divergence_window` are set. Plateau fires when the score series is unchanged for `plateau_window` consecutive iterations; divergence fires when quality regresses for `divergence_window` consecutive iterations. Both are overridable per cycle in the template.

See also [[mechanics/convergence]], [[mechanics/route_back]], and [[Pipeline-and-Stages]].
