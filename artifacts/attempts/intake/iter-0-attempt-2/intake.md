[bug] a failed result write never reads as a current result — the test stage and intake still ignore it

## Goal

A stage whose result file failed to save never reports a result. In particular, it never leaves an earlier round's data looking like this round's.

## What is wrong today

Most stages write `… | atomic_write "$f" && stage_result_add …`, so a failed write leaves no result, and a missing result fails closed (ADR-068 §8, `stage_result_is_current`). Two writers still don't:

- **`_test_write_result`** (`plugins/tool/test/plugin.sh`) checks `PIPESTATUS[0]`, which is jq's exit code, not the write's.
  - When the write fails and the previous round's file is still there, `stage_result_add` puts this round's outcome into the old file and rewrites it.
  - The result then looks current, but carries the old round's pass/fail counts and findings.
- **`_intake_run_inner`** (`plugins/agent/intake/plugin.sh`) ignores whether writing `scope-manifest.md` and `intake.md` succeeded, and returns 0.
- Nothing stops a new `| atomic_write` with no check from being added.

## ADR

- ADR-054 §5 (the result file is the stage's only answer) and its #2366 amendment (contract 3, one `outcome`).
- ADR-068 §8: a stale result counts as absent.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** The test stage's result write fails while an earlier round's result file exists. The test stage's result is either absent or `broken` (reason `result_write_failed`). It never has a fresh outcome on top of the old round's counts.
- **R2.** Intake's write of `scope-manifest.md` or `intake.md` fails. Intake exits non-zero, and its reason names the file.
- **R3.** A lint (in `npm run lint`) fails any `| atomic_write` in `core/`, `plugins/` or `scripts/` whose exit status is not checked (`&&`, `||`, `if !`, or `PIPESTATUS` index of the write). Existing safe uses pass.

## Scope

- **Code:** `plugins/tool/test/plugin.sh`, `plugins/agent/intake/plugin.sh`, a new lint under `scripts/lib/` wired into `npm run lint`.
- **Tests:**
  - `tests/unit/test-plugin-result-write-fallback-test.sh`
  - `tests/unit/test-result-reason-contract-test.sh`
  - `tests/unit/plugin-primary-output-atomic-test.sh`
  - intake's tests (`grep -rl '_intake_run_inner' tests/ plugins/agent/intake/tests/`)
- **Out of scope:** a new write helper. `stage_result_write` is the one result writer.
