# ADR-034 — Targeted test re-run in build_test_cycle (confirmed by the stage)

**Status:** Accepted (2026-06-15)
**Amended:** 2026-09-16 (#2121) — the targeted set is selected by PATH: a changed file selects every test under `tests/` or `plugins/*/*/tests/` that names its repo-relative path, the same for its bare basename only when that basename is unique in the repo (`plugin.sh`/`manifest.yaml` matched 286 files — 39 minutes — on #1841), and, for a file inside a plugin, that plugin's own `tests/`; the design's declared TESTFILES (optional input `design`) are always in the set. The red-set hint is unchanged.
**Amended:** 2026-09-16 (#2117) — the full-suite gate is exempt from ADR-021's unchanged-tree reuse: a `run_mode=targeted` test pass is never reused across an `empty_diff` iteration, so the gate iteration always gets its full run. (Superseded by #2144: a test pass is now always full-suite confirmed, so the reuse rule reads no run mode.)
**Amended:** 2026-09-19 (#2144) — the confirmation is the test stage's own job. When the targeted subset passes, the stage runs the full command in the same invocation and reports that result (`run_mode: targeted+full`, the subset's result under `data.targeted`); a red subset is reported as-is. The orchestrator's full-suite gate — `_cycle_read_test_run_mode`, the one-shot convergence suppression, the `ZBUILD_TEST_FULL_SUITE_GATE` lifecycle and the `cycle.test.full_suite_gate` event — is deleted. Its decision read a test artifact from the state dir, and on run 35412141973 (#1840) that artifact, left by `build_test_cycle` iteration 2, held `design_verify_cycle` — a cycle with no test member — at its maximum for 52 minutes while both of its exit conditions matched. The cycle's iteration rules no longer mention run modes; each iteration ends with one verdict that is what it says.
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

3. **Full-suite confirmation (as amended by #2144).** A targeted pass is insufficient
   to converge: it may miss a side-effect regression in an unaffected file. When the
   targeted subset passes, the test stage runs the full command itself, in the same
   invocation, and the full run's verdict, counts, red set and `tree_sha` are what it
   reports (`run_mode: "targeted+full"`; the subset's command and counts are kept under
   `data.targeted`). A red subset is reported as `run_mode: "targeted"` with no full run —
   the builder gets its fast feedback. The orchestrator knows nothing of run modes.
   (Until #2144 the orchestrator suppressed convergence once and armed
   `ZBUILD_TEST_FULL_SUITE_GATE` for an extra iteration; see the amendment above.)

## Consequences

- Convergence iterations run a fast subset; correctness is preserved because a green
  subset is always followed by the full suite before the stage reports a pass.
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
  changed files. (The run-mode reader and gate intercept were deleted by #2144.)

## Verification

- Unit: `plugins/tool/test/tests/test-test.sh` T13–T17 (extract/compute/build-cmd/
  targeted pass → `run_mode=targeted+full` / red subset stays targeted);
  `tests/unit/core-pipeline-cycle-final-gate-test.sh` (feedback export; no run-mode
  reader; a stale `run_mode=targeted` artifact does not hold `design_verify_cycle`).
- Integration (end-to-end): `tests/integration/build-test-cycle-targeted-rerun-test.sh`
  drives the REAL cycle + REAL test stage: iter-1 full (seeds red set) → iter-2 targeted
  pass confirmed by the full suite in the same stage → converged on iteration 2. (Red
  before #846: targeted run → `verdict=error` → blocked. Red before #2144: a third
  iteration and a `cycle.test.full_suite_gate` event.)

## Amendment (2026-06-17, #929) — `--files` invocation hardening

The targeted-rerun contract is "run each file in its own process so a failure
never blocks the rest." But the `{files}` list is built partly by grepping
`tests/` for a changed source basename (`_test_compute_target_files`), which can
surface **non-test** paths (mutation `*.md` specs, fixtures, sourced helpers).
`scripts/run-tests.sh --files` ran **every** passed path as `bash "$f"` with no
filter, no stdin guard, and no timeout — so a markdown spec (`tests/mutation/cache.md`,
unbalanced backtick → bash blocks on stdin) **wedged the build_test_cycle test
stage for 3.5 hours** in a #911 dogfood (CI never hit it — CI uses the tier path,
not `--files`).

Hardened both the `--files` and tier loops (via the shared `_rt_run` helper):
1. **Filter:** `--files` skips any input that is not `*-test.sh` (before the
   `N/M` count, so the denominator only reflects real tests).
2. **Stdin guard:** every test-file invocation runs with `</dev/null` — a file
   that reads stdin gets EOF instead of blocking.
3. **Per-file timeout:** each invocation is wrapped in `gtimeout`/`timeout`
   (`ZBUILD_TEST_FILE_TIMEOUT`, default 300s, 0 disables; degrades to no-timeout
   when neither is installed). A hung/looping file is killed and surfaces as a
   normal `FAIL <file>` — the honest outcome — never an unbounded wait. The
   load-bearing `3>/dev/null` (#586 stage-io fd-3 guard) is preserved.

The output grammar the verdict parser keys on (`unit: N/M passed`,
`unit: FAIL <path>`) is unchanged. Verified by `tests/unit/run-tests-files-guard-test.sh`
(non-test skipped; stdin-reading test returns; infinite-loop test killed by the
per-file timeout, not the outer bound) + the updated `tests/unit/scripts-run-tests-fd3-test.sh`.

## Amendment (2026-07-03, issue #1208) — second convergence-suppression instance

This ADR introduced the FIRST one-shot convergence-suppression in the cycle orchestrator
(the targeted-pass full-suite gate: `converged=0` + `run_mode=targeted` → suppress once,
arm the full-suite re-run — deleted by #2144). Issue #1208 adds a SECOND, sibling
suppression using the same pattern and placement (right after `_cycle_check_until`): a **mid-flight build** (verdict
`did_not_finish` from a router timeout / dispatch error) also flips `converged=0`→`1` and
emits `cycle.build_unfinished.suppressed_convergence`, so a timed-out build can never
ratify a false `complete` on a stale/partial tree. Unlike the full-suite gate, the
mid-flight suppression has NO max_iterations fail-safe guard (it must suppress even on the
last iter — a timed-out build is never a clean resting point); at exhaustion the by-severity
cascade (ADR-021 Amendment #1208) then routes the outcome. A clean empty-diff stall is a
resting point and is NOT suppressed. See ADR-021 Amendment #1208.
