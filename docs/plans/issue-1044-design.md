# Issue #1044 — acceptance-gate verdict load-bearing at completion

The acceptance-gate writes `artifacts/acceptance-gate-result.json`
`{"verdict":"fail","failures":[...]}` and returns rc=1 for EVERY fail class, but
`build_review_cycle` still converged on `review.verdict==approve`, so a failing
gate never blocked `status=complete`. The gate's fail was inert.

## Decision (Option C, not `blocking: true`)

A blanket `blocking: true` is wrong: the gate returns rc=1 for the RECOVERABLE
`untagged_spec` class too, which is fed back to `build` via the #951 edge
(`acceptance-gate.gate_result → build.prior_acceptance_feedback`). Hard-aborting
would kill that retry loop. The gate's three levels are SEQUENTIAL, so
`failures[]` is homogeneous per run — `untagged_spec` (L1) never mixes with
`tautology`/`inert_wiring` (L2/L3).

So we make the verdict load-bearing ONLY at the completion decision, EXCLUDING
`untagged_spec`: a new highest-priority status-ladder branch in
`core/pipeline/cycle-orchestrator.sh` fires `term_rc=8`
(`reason=acceptance_contract_failed`, `overall_status=acceptance_failed`) before
the `converged` branch, gated by `_cycle_acceptance_terminal_failure`. The
membership guard (`acceptance-gate ∈ _CYCLE_STAGES`) ensures inner cycles
(`build_test_cycle`) are never affected. rc=8 routes through the existing
terminal fan-in so the runner emits `pipeline.end status=failed`.

```acceptance
SPEC-1: non-feedback acceptance failure (inert_wiring/tautology) is classified terminal.
SPEC-2: untagged_spec-only failure is NOT terminal (feedback loop preserved).
SPEC-3: acceptance-gate not a cycle member → never blocks (membership guard).
SPEC-4: review.verdict=approve + terminal acceptance failure halts the cycle rc=8 (pipeline failed), not complete.
TESTFILES:
  tests/unit/core-pipeline-cycle-acceptance-terminal-test.sh
  tests/integration/cycle-acceptance-terminal-failure-test.sh
WIRING:
  core/pipeline/cycle-orchestrator.sh
```
