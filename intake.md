[bug] a run that recorded itself as failed still opens a non-draft PR

> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): absorbed #1724 (closed as merged into this issue), so the PR body must now also show the cycle's convergence state; added current file:line evidence.

Part of #1794 (Phase 1).

**Classification: ENGINE — `plugins/tool/pr-open/plugin.sh`.**

A run whose own state file records `failed` still opens a **normal, non-draft** pull request. Observed end to end: a build cycle failed all five iterations, the gate's reason was correct and specific, `pipeline-state.json` recorded `failed`, and the resulting non-draft PR was merged.

Whatever else is true about convergence, a run that knows it failed must not present its output as ready to merge.

## Merged from #1724 — the PR body hides non-convergence

Run `20260804113756-2356` ([run 30905539852](https://github.com/ezigus/zBuild/actions/runs/30905539852)): `build_test_cycle` used all 5 iterations with `shape-floor` red (`cycle.unconverged cycle_id=build_test_cycle iter=5`, `pipeline.end status=failed reason=max_iterations`). PR #1720 then opened with `**Test verdict:** pass` as its most prominent line and nothing saying the build never converged.

The PR opening itself is intended: `build_test_cycle` is `on_max: continue` (`config/templates/simple.yaml:256`), the ADR-019 fall-through that hands an unconverged attempt to the operator. The defect is that the PR it produces hides the thing the operator is being asked to judge.

## Where it is on main

- Draft is only ever the static template setting: `_TPL_PR_DRAFT` → `--draft` (`plugins/tool/pr-open/plugin.sh:117-118`, `:339`). Nothing reads the pipeline status or cycle convergence.
- The body is built from `plan_summary`, the advisory section and `test_verdict` only (`plugins/tool/pr-open/plugin.sh:316-337`). It never mentions `cycle_iterations`, `max_iterations` or non-convergence.
- The data exists: `pipeline-state.json` (`cycle_iterations.build_test_cycle`) and `gate-aggregator-result.json` (the failing gates).
- When the gate fails, pr-delivery's `auto_unless_flagged` branch declines to merge and falls through to `pr_open_run`, which opens a normal non-draft PR (`plugins/agent/pr-delivery/plugin.sh:110-128`).

## Fix

When the pipeline status is `failed`, or the build cycle did not converge, open the PR as a draft and say why in the body. The body always states the cycle's convergence state: iterations used out of the maximum, and **not converged** when that is the case, with the failing gates named, e.g.

```
> ⚠️ **build_test_cycle did not converge** (5/5 iterations). Failing gates: shape-floor.
> Opened under ADR-019 fall-through for operator judgement — not a green deliverable.
```

Read the state that already exists (`pipeline-state.json`, `gate-aggregator-result.json`) rather than adding new plumbing. Converged runs still open non-draft by default (#1436); draft becomes a consequence of failure or non-convergence, not a new global default.

## Acceptance

- [ ] A failed run opens a draft PR, never a normal one.
- [ ] A run whose build cycle ends `max_iterations` opens a draft PR.
- [ ] The PR body names the failing gate and the reason.
- [ ] The PR body shows the cycle's iterations used out of the maximum, and says **not converged** when it did not converge.
- [ ] A passing, converged run still opens non-draft (#1436 policy unchanged).
- [ ] An explicit `pr_draft: true` template setting still forces draft regardless of convergence.
- [ ] Regression tests covering the failed-run and unconverged paths, each red on main before the fix.

Refs #1724, #1436, ADR-019.
