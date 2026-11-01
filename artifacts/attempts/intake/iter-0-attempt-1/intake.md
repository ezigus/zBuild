[bug] --resume and --from-stage trust and rehydrate every stage that already ran — the live dispatch path replays from the start today

## Decision

**A resume trusts every stage that already ran.** Each stage the interrupted run completed counts as done, and its outputs are put back (rehydrated) exactly as they were when the run stopped. The run picks up at the stage that was interrupted, which runs again from its start. `--from-stage <s>` works the same way: every stage before `<s>` is trusted and rehydrated, and the run starts at `<s>`.

## What is wrong today

- In `main` in `core/pipeline/runner.sh`, the **live** dispatch-unit loop never reads `resume_mode`, `skip_until_stage` or `stage_statuses`. Only the legacy linear loop (#1807) skips completed stages. So `--resume` replays the run from the start.
- `--from-stage` is validated and `pipeline.skip_to_stage` is emitted, but nothing acts on it. The run says it skips ahead and then replays everything.
- Auto-resume reads `$state_dir/pipeline-state.json` before the run switches to its per-run folder `runs/<run_id>/` (ADR-059), so it may never find the interrupted run's state.

## ADR

- **Amend ADR-006** (resume contract) with the decision above. ADR-006 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.
- **Amend ADR-050 §6** to draw the line explicitly. ADR-050 §6 / #2299 says "never skip a stage on the basis of prior output". That rule governs a **new** run reusing an **earlier run's** work, and it stays. Resume continues **the same run** and is governed by ADR-006. A test pins each side.
- Rehydration follows the same path the hydrate stage already uses (ADR-050, `plugins/tool/hydrate`), so "exactly as before" means the same files at the same paths.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** A run is interrupted during stage *k*. Resuming it does not dispatch stages 1…*k−1*, their outputs are present and byte-identical to what they were at the interruption, and stage *k* is dispatched.
- **R2.** Inside a loop (e.g. build → test), a run interrupted mid-round resumes at the interrupted stage of that round. The loop's iteration count and state are restored, not reset.
- **R3.** `--from-stage <s>` dispatches `<s>` first, with every earlier stage's outputs rehydrated. It never emits `pipeline.skip_to_stage` and then runs an earlier stage.
- **R4.** `--from-stage <s>` naming a stage with no prior output to rehydrate refuses with a reason, and does not start.
- **R5.** Every way to resume (`--resume`, auto-resume on restart, and `zbuild pipeline resume --run-id`) finds the interrupted run's state in `runs/<run_id>/` and behaves as R1. Each has its own test.
- **R6.** A run with no prior state behaves exactly as today. This is a guard.
- **R7.** A **new** run of the same issue still never skips a stage because of an earlier run's output (ADR-050 §6). This is a guard.

## Scope

- **Code:** `core/pipeline/runner.sh` (live dispatch loop, startup resume detection), possibly `core/pipeline/cycle-orchestrator.sh` (loop state on resume), `plugins/tool/hydrate/plugin.sh` (reuse, don't duplicate).
- **ADRs:** `docs/adr/ADR-006-resume-contract.md`, `docs/adr/ADR-050-prior-work-reuse-contract.md`.
- **Tests that pin this behaviour:**
  - `tests/integration/pipeline-resume-test.sh`
  - `tests/unit/resume-default-test.sh`
  - `tests/unit/runner-startup-preflight-test.sh`
  - `tests/integration/core-pipeline-cycle-build-test-wiring-test.sh`
  - `tests/integration/prior-work-reuse-integration-test.sh`
  - `tests/unit/prior-work-reuse-contract-test.sh`
- **Order:** runner.sh is a hotspot. Do not run this in parallel with another issue that edits the dispatch loop (#1714 touches the allow-list builder in runner.sh).
