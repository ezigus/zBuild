# ADR-034 — Targeted test re-run in build_test_cycle (with full-suite gate)

**Status:** Accepted (2026-06-15)
**Related:** ADR-021 (cycle semantics), ADR-022 (test assessment), ADR-011 (pluggable backends)
**Issue:** #846. Surfaced by dogfood `20260612173055-58001` (full suite re-run ~15min × 6 iters).

## Context

`build_test_cycle` re-runs the **entire** test suite every iteration. When the build
fixes a bounded subset of failures, re-discovering the same red set by running
everything is wasteful (the #846 dogfood spent ~90min running the full suite 6×).

A first cut (the original #846 commits) added the red-set + targeted machinery but was
**inert/broken**: the targeted command was hardcoded to `bash '<file>' && bash '<file>'`,
which (a) is a zbuild-ism that doesn't generalize, (b) short-circuits on the first
failure via `&&`, and (c) produces each file's *per-file* output ("All N tests passed"),
which `_test_parse_summary` does NOT recognize → `verdict=error` → the cycle's blocked
detector fires → the cycle terminates `rc=5 reason=blocked` instead of converging. So
targeting never actually worked.

## Decision

1. **Targeted phase (iter 2+).** When the prior iter left a red set
   (`ZBUILD_TEST_RED_SET`) and/or `ZBUILD_TEST_CHANGED_FILES`, and the full-suite gate is
   not armed, the test stage runs only the union of previously-red files and files that
   grep-reference a changed source basename (`_test_compute_target_files`). The
   `test-results.json` records `run_mode: "targeted"`.

2. **The targeted command is repo-configurable.** "How to run a subset of tests" is
   framework/repo-specific, so it is NOT hardcoded. `ZBUILD_TEST_CMD_TARGETED` is a
   template containing the literal `{files}`, rendered with the shell-quoted file list
   (`_test_build_targeted_cmd`). It defaults to the repo's
   `scripts/run-tests.sh --files {files}` subset mode when present; otherwise the stage
   falls back to the full command and `run_mode` stays `"full"` (never a broken targeted
   run). Other repos set their framework's subset command (`jest {files}`,
   `pytest {files}`, `cargo test {files}`). The targeted runner MUST (a) run every file
   independently — no `&&` short-circuit — and (b) emit output the verdict parser
   recognises. zbuild's `run-tests.sh --files` does both: it loops the files and emits the
   `unit: N/M passed` tier-summary, **identical to the full run** (so verdict + red-set
   parsing are unchanged between modes).

3. **Full-suite gate.** A targeted pass is insufficient to converge: it may miss a
   side-effect regression in an unaffected file. When the convergence predicate fires
   while `run_mode == "targeted"` (and iter < max), the orchestrator suppresses
   convergence once, emits `cycle.test.full_suite_gate`, and arms
   `ZBUILD_TEST_FULL_SUITE_GATE` for the next iter — forcing a full run that must pass
   before the cycle truly converges.

## Consequences

- Convergence iterations run a fast subset; correctness is preserved by the mandatory
  full-suite gate before green.
- The targeted mechanism generalises across frameworks via `ZBUILD_TEST_CMD_TARGETED`;
  unconfigured repos degrade safely to full runs.
- `run-tests.sh` gains a `--files` subset mode (single source of truth for the full and
  targeted formats).

## Implementation Notes (#846)

- `plugins/tool/test/plugin.sh` — `_test_build_targeted_cmd` renders the `{files}`
  template (empty → caller runs full); `_test_run_inner` resolves the template
  (`ZBUILD_TEST_CMD_TARGETED` → `run-tests.sh --files` auto-default → full) and writes
  `run_mode`.
- `plugins/tool/test/lib/parse.sh` — `_test_extract_failing_files` builds the red set
  from `^(unit|...): FAIL <path>` lines.
- `scripts/run-tests.sh` — new `--files <f...>` mode: per-file loop emitting
  `unit: N/M passed` + `unit: FAIL <f>`.
- `core/pipeline/cycle-orchestrator.sh` — `_cycle_apply_feedback` exports the red set +
  changed files; `_cycle_read_test_run_mode` + the gate intercept emit
  `cycle.test.full_suite_gate`.

## Verification

- Unit: `plugins/tool/test/tests/test-test.sh` T13–T17 (extract/compute/build-cmd/
  run_mode=targeted/gate-forces-full); `tests/unit/core-pipeline-cycle-final-gate-test.sh`.
- Integration (end-to-end): `tests/integration/build-test-cycle-targeted-rerun-test.sh`
  drives the REAL cycle + REAL test stage: iter-1 full (seeds red set) → iter-2
  `run_mode=targeted` → `cycle.test.full_suite_gate` → iter-3 full → converged. (Red
  before this fix: targeted run → `verdict=error` → blocked.)
