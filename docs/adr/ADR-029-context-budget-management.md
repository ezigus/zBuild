# ADR-029 — Context budget management in cycle iterations

**Status:** Proposed (2026-06-11)
**Related:** ADR-021 (cycle semantics), ADR-028 (shared LLM-agent framework)

## Context

The `#754` dogfood `run_id 20260611072619-15296` showed three consecutive 900s `claude max_turns reached` (rc=124) failures inside the build_test_cycle iter 2 build stage. Each timeout burned 15 minutes of wall-clock + token budget; the cycle had no notion of "this prompt is too large for the current max_turns" so it just kept retrying the same shape.

The cause: cycle context accumulates per iter. Each iter's prompt gets larger:

- Plan iter 2 prompt: original goal + `prior_plan` + `prior_impact_feedback`
- Build iter 2 prompt: original plan + `prior_test_assessment.failure_summary_md` (often 2-3KB of markdown)
- Build iter 3 prompt: above + accumulated state

The model eventually exhausts its turn budget producing tool calls (Read/Grep/Edit) before reaching `LOOP_COMPLETE`. The router classifies the rc=124, but there's no orchestrator-level rule that says "retrying this is wasted budget; abandon."

## Decision

Add cycle-level context budget management with three guards:

### G1. Per-iter prompt size budget

Each cycle declares (defaults if unset):

```yaml
build_test_cycle:
  type: cycle
  ...
  context_budget:
    max_prompt_chars: 50000      # ~12K tokens at 4 chars/token average
    compress_strategy: tail_truncate  # or summary, head_keep
```

Before invoking a cycle member, the orchestrator measures the assembled prompt. If it exceeds `max_prompt_chars`:

- `tail_truncate`: trim oldest sections (typically prior_test_assessment tail) until under budget
- `summary` (future): invoke a T1 model to summarize the cumulative feedback before splicing
- `head_keep`: trim middle sections, preserve task header + most-recent feedback

The orchestrator emits `cycle.context.compressed` event with `original_chars`, `final_chars`, `strategy` so postmortem can see what was dropped.

### G2. Repeated-timeout fast abandon — **REVERSED / REMOVED (issue #1208)**

> **Amendment (2026-07-03, issue #1208): G2's fast-abandon is REMOVED.** A build-stage
> timeout is now **NEVER fatal**. The single fatal condition is the build/test cycle
> exhausting `max_iterations` without a clean, passing convergence (see ADR-021
> Amendment #1208). A repeated router timeout no longer abandons the cycle
> (`cycle.member.timeout_abandoned` / `return 4` deleted); the timed-out attempt simply
> consumes an iteration and the cycle retries — each attempt is cheap because the build
> self-yields on an empty diff. At exhaustion the outcome is split **by severity** (tests
> failing → `rc=8` halt; tests passing-but-unclean → `rc=2` unconverged→review). The
> per-member timeout **counter** and the `cycle.member.timeout` event are RETAINED to
> feed **G3** (below), which is KEPT. NB: with #1208 Changes 1–2 a build timeout now
> surfaces as `verdict=did_not_finish` (not `verdict=error reason=router_timeout`), so
> for the build/test cycle the G2 counter branch is largely dormant; it remains intact
> for any member that still reports an error-class `router_timeout`/`router_oom_kill` so
> G3 escalation keeps working.

The original (now-removed) G2 behavior, for history: when a cycle member returned `verdict=error reason=router_timeout`, the orchestrator tracked consecutive timeouts per member and, on the 2nd consecutive, aborted the cycle iter with `cycle.member.timeout_abandoned`. Rationale at the time: save 900s per avoided third retry. #1208 supersedes this — "run all tries; only exhaustion-without-convergence is fatal."

### G3. Per-stage `max_turns` budget tracking

When a stage's `claude --max-turns N` is exhausted (rc=124), the orchestrator notes the exhaustion in `cycle.iter.N.stage.<name>.turns_exhausted=true`. On the SAME cycle iter retry, increase `max_turns` by 50% (capped at 2× the stage default).

The signal: if the model needed 25 turns and failed, maybe it needs 38. But if it fails at 38, it's a different problem (not turn budget); cap and abandon per G2.

## Consequences

**Wins:**

- 30+ min wasted-per-cycle savings on the observed dogfood pattern
- Honest signal: "the prompt is too big" or "the task is too complex" surfaces in events.jsonl, not as a silent budget exhaustion
- Compresses cycle context predictably, so prompt growth doesn't compound across iters

**Costs:**

- Cycle config schema gains a new optional block
- Orchestrator complexity: tracking per-member retry state across iters
- Compression strategy choice is a tunable that operators have to understand

**Validation:**

- Re-dogfood after implementation: a deliberately oversized prompt should produce ONE timeout, then `cycle.member.timeout_abandoned`, NOT three consecutive 900s burns
- Measure aggregate wall-clock + token cost per cycle iter; compare to baseline

## Status: Proposed → Accepted when implemented

Implementation depends on ADR-021 R2 (rc=124 propagation) landing first so `_router_rc_classify` can actually distinguish timeout from generic failure.

## Implementation Notes

Depends on ADR-021 R2 (rc=124 propagation) landing first so `_router_rc_classify` actually receives the timeout code.

Implementation order:

1. **R2 from ADR-021** — fix the router rc translation so rc=124 propagates verbatim. Cycle-orchestrator-level changes; tests at `tests/unit/core-pipeline-cycle-router-rc-test.sh` (new) and integration test with synthetic gtimeout.
2. **G2: Repeated-timeout fast abandon** — smallest code change, biggest wall-clock impact. Track per-member consecutive timeout count in cycle state; on 2nd timeout abandon the iter. Lands in `core/pipeline/cycle-orchestrator.sh`.
3. **G3: Per-stage max_turns escalation** — orchestrator notes turns_exhausted; on next iter's same-member retry, bump max_turns by 50% capped at 2× default.
4. **G1: Per-iter prompt size budget with compression** — biggest scope; schema addition + compression strategy implementation. Defer to a follow-up after G2/G3 prove the principle.

Each step is a separate PR with TDD coverage at unit + integration.
