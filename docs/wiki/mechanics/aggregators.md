# aggregators

When a template runs several stages in parallel — a map group, a parallel group, or a set of review lenses — each one produces its own verdict. An aggregator collects those individual verdicts into one answer so the pipeline can move forward without knowing how many stages ran or what they were named.

Two kinds of aggregator exist. A **gate-aggregator** makes a binding decision: it merges the mechanical pass/fail verdicts of a gate group into the single go/no-go that controls whether `build_test_cycle` may proceed. A **review-aggregator** is advisory: it merges review-lens findings into one report and never blocks a merge on its own.

## How to use

Add an aggregator stage explicitly in your template `flow:` after the group it merges. Aggregators are **never auto-injected** — they must appear by name in the roster. The stages they merge are discovered from that roster, not from hardcoded stage names.

Gate-aggregator (mechanical, build-blocking):

```yaml
flow:
  - id: lint
    plugin: gate-aggregator
    convergence: gate
    inputs:
      roster: [lint-style, lint-types, lint-contracts]
```

Review-aggregator (advisory, never blocks):

```yaml
flow:
  - id: review-summary
    plugin: review-aggregator
    inputs:
      roster: [review-security, review-perf, review-correctness]
```

## Reference

**Defined in:** `core/pipeline/verdict.sh`

| Property | Value |
|---|---|
| Mechanic id | `aggregators` |
| Plugins | `gate-aggregator` · `review-aggregator` |
| Roster-driven | Yes — stages listed in `inputs.roster`; no name-pattern matching |
| Auto-injected | No — must appear explicitly in the template `flow:` |

**gate-aggregator behavior:**
- Reads each roster member's verdict from the run state.
- Emits `pass` only when every member passes; any `fail` or `warn` yields the aggregated verdict's worst class.
- Is the sole authoritative merge-blocker for its group. See [[mechanics/gates]].

**review-aggregator behavior:**
- Collects findings from each roster member's advisory report artifact.
- Emits a single merged report; never sets a blocking verdict.
- Convergence for advisory cycles is owned by the build/test cycle, not this aggregator (see [[mechanics/convergence]]).

**Verdict classes** (from `core/pipeline/verdict.sh`):

| Raw verdict | Class |
|---|---|
| `pass`, `approve` | `pass` |
| `request_changes`, `incomplete`, `did_not_finish` | `warn` |
| `fail`, `error`, `block`, `scope_violation`, `corrupt_diff`, `route_*` | `fail` |
| missing / malformed primary | `warn` + `stage.verdict.missing` event |

## Advanced

_Newcomers can skip this section._

**ADR references:**
- **ADR-040 §5** — defines the gate-aggregator / review-aggregator split and prohibits auto-injection. Advisory review is never authoritative; the build/test cycle owns convergence.
- **ADR-047 §3** — the canonical verdict channel per stage. A JSON primary carries `.verdict` inline; a non-JSON primary (e.g. `design.md`) pushes verdict to a `<stage>-verdict.json` sidecar. The aggregator reads whichever channel the stage used.
- **ADR-045 / #1219** — `route_*` verdicts (e.g. `route_design`) classify as `fail` for indicator purposes but pass through as raw strings so `_cycle_detect_blocked` can distinguish them from a plain test failure that should keep iterating.

**Structural-failure pass-through (#550):** `verdict_classify` normally collapses `error`, `corrupt_diff`, and `block` to `fail`. The runner preserves the raw string for these three so `_cycle_detect_blocked` can abort the cycle early rather than treating them as "test ran and failed — iterate." This pass-through is internal to `runner_read_stage_verdict`; aggregator plugins see the classified form.

**Planned — synthesize mode (#1350):** A future third aggregator kind, `synthesize`, will use an LLM reducer to condense N draft artifacts into one output. It is not yet implemented; this page will be updated when it ships.

See also: [[mechanics/gates]], [[mechanics/convergence]], [[mechanics/parallel]], [[mechanics/map]], [[plugins/gate-aggregator]], [[plugins/review-aggregator]].
