# Design: Draft PR on Failed / Unconverged Run (Issue #1799)

## Architectural Decision Summary

**Goal:** When a zBuild run ends in a failed state or a build cycle reaches `max_iterations` without converging, the PR it opens must be a draft, and the PR body must name the failing gate and convergence state. Passing, converged runs continue to open non-draft PRs.

**Context:** `plugins/tool/pr-open` already has draft-mode support via `_TPL_PR_DRAFT` (the template's `pr_draft:` key). The state file written by the runner records `.status` (e.g. `"failed"`) and `.cycle_iterations[<id>].status` (e.g. `"max_iterations"`). Both are available to `_pr_open_run_inner` via the `state_file` argument it already receives. The gate-aggregator writes a result artifact with `failed[]` and `reason` that identifies which gates blocked convergence; pr-delivery already declares `gate_aggregator_result` as an optional input, and pr-open already reads from `ZBUILD_STAGE_INPUTS` (the calling stage's inputs index, ADR-055 §1).

**Decision:** Add state-aware draft forcing directly in `_pr_open_run_inner`: read `state.status` and `cycle_iterations` from the state file to override `_draft_bool` to `true` on a failed or unconverged run. Extend `_pr_open_compose_body` (in `advisory-section.sh`) to accept and render a convergence section when the run was not converged. Declare `gate_aggregator_result` as an optional input in the pr-open manifest. The `_TPL_PR_DRAFT=true` path continues to take effect before the new state check, so it remains authoritative.

```scope
plugins/tool/pr-open/plugin.sh
plugins/tool/pr-open/lib/advisory-section.sh
plugins/tool/pr-open/manifest.yaml
plugins/tool/pr-open/tests/pr-open-test.sh
plugins/agent/pr-delivery/plugin.sh
tests/integration/pr-pipeline-test.sh
tests/unit/plugin-artifact-goldens-test.sh
tests/golden/pr-result-artifact.golden
docs/wiki/plugins/pr.md
core/pipeline/state_helpers.sh
```

```acceptance
SPEC-1[code]: When state.status is "failed", pr-open forces _draft_bool=true before invoking gh, regardless of _TPL_PR_DRAFT covers: R-1 R-7
SPEC-2[code]: When any state.cycle_iterations[*].status equals "max_iterations", pr-open forces _draft_bool=true before invoking gh covers: R-2 R-7
SPEC-3[code]: When SPEC-1 or SPEC-2 applies, the PR body includes a convergence section naming which cycle was unconverged, iterations_used/max, and the phrase "not converged" covers: R-3 R-4
SPEC-4[code]: When gate_aggregator_result (from ZBUILD_STAGE_INPUTS) is present with a failing verdict, the PR body names the failing gates and the gate-aggregator reason covers: R-3
SPEC-5[done]: A run with state.status not "failed", no max_iterations cycle, and _TPL_PR_DRAFT unset produces a non-draft PR (draft=false in pr-result.json) covers: R-5 evidence: plugins/tool/pr-open/plugin.sh:131 tests/integration/pr-pipeline-test.sh
SPEC-6[done]: _TPL_PR_DRAFT=true forces draft=true regardless of run status, because the _TPL_PR_DRAFT normalization (plugin.sh:131) runs before the new state check and ORs into _draft_bool covers: R-6 evidence: plugins/tool/pr-open/plugin.sh:131 plugins/tool/pr-open/tests/pr-open-test.sh
WIRING:
plugins/tool/pr-open/plugin.sh
TESTFILES:
SPEC-1: plugins/tool/pr-open/tests/pr-open-test.sh
SPEC-2: plugins/tool/pr-open/tests/pr-open-test.sh
SPEC-3: plugins/tool/pr-open/tests/pr-open-test.sh
SPEC-4: plugins/tool/pr-open/tests/pr-open-test.sh
```
