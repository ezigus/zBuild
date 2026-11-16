# Design — GitHub label claim (#1764)

## Goal

Prevent two concurrent zBuild runs on the same issue from overlapping across machines by using a
GitHub label (`zbuild:claimed`) as a soft cross-machine claim. The existing local flock
(`core/state/issue-lock.sh`) remains for intra-machine serialisation; this change adds the
inter-machine layer on top of it, using the same acquire-before-dispatch / release-on-exit shape.

## Context

`core/state/issue-lock.sh` is a filesystem flock: effective on one host, invisible from another.
Issue #1764 asks for a GitHub label that any run can see before it starts. The status-comment
sidecar already shows per-run progress on the issue; the new claim comment is a small companion
comment (machine-readable marker + holder string) that lets a refusing run name the holder.

## Decision

Add `core/claim/claim.sh`:
- `zbuild_claim_acquire <issue> <run_id> <slug>` — check for `zbuild:claimed` on the issue; if
  absent, add it and post a small claim comment (marker `<!-- zbuild-claim run_id=... -->`); if
  present, find the most recent claim comment, extract the holder string into `_ZBUILD_CLAIM_HOLDER`,
  and return 1.
- `zbuild_claim_release <issue> <slug>` — remove the label; PATCH the claim comment to show
  `Status: finished`. Both operations are advisory (failures logged, run never fails).

Wire it into `core/pipeline/runner.sh`:
- Source at the top alongside `core/state/issue-lock.sh`.
- Call `zbuild_claim_acquire` immediately after `zbuild_issue_lock_acquire` succeeds, before
  `_runner_enter_worktree`. On return 1, emit `pipeline.refused.claimed`, print the holder
  string, and return 1 (same shape as the issue-lock refusal).
- Call `zbuild_claim_release` in `_runner_abort_trap` immediately after `zbuild_issue_lock_release`,
  using the same `declare -F` guard.

Register `pipeline.refused.claimed` in `config/event-schema.json`:
- Follows the same pattern as `pipeline.refused.issue_locked` and `pipeline.refused.run_cap`.
- Required so `tests/unit/event-schema-emitted-coverage-test.sh` does not fail on the new emission.

The "progress comment" referenced by the requirements is this new claim comment, not the
stage-progress sidecar comment (which is unchanged). It is created at claim-time (before first
stage), updated to `finished` on every exit path, and used by a refusing run to identify the holder.

Holder string:
- CI (`GITHUB_ACTIONS=true`): `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`
- Local: `run_id=<id> machine=<hostname>`

The label name is the constant `zbuild:claimed` — no hostname, same in every environment.

Graceful degradation: if `gh` is not available, not authenticated, `NO_GITHUB=true`, or the run has
no issue number, `zbuild_claim_acquire` returns 0 immediately (skip). The local flock still
serialises same-machine runs. Skipping is logged to the run's state dir but never fails the run.

Known limitation: check-then-label is not atomic at GitHub. Two machines racing may both see the
label absent and both succeed. The mechanism prevents honest accidental overlap; a strict distributed
mutex is out of scope (RQMECH-1, RQMECH-2).

```steps
- Create core/claim/claim.sh: zbuild_claim_acquire and zbuild_claim_release, with graceful degradation gates (no issue, NO_GITHUB, gh absent/unauthed) | areas: core/claim/claim.sh
- Register pipeline.refused.claimed in config/event-schema.json following the pattern of pipeline.refused.issue_locked | areas: config/event-schema.json
- Wire core/claim/claim.sh into runner.sh: source at top; call zbuild_claim_acquire after zbuild_issue_lock_acquire; call zbuild_claim_release in _runner_abort_trap with declare -F guard | areas: core/pipeline/runner.sh
```

```acceptance
DSCLA-1[code]: When an issue-bound run starts and zbuild:claimed is absent, the label is added to the issue before the first stage dispatches covers: RQCLA-1, RQLAB-1
  Given: a run is started with an issue number; zbuild:claimed is not on the issue
  When: zbuild_claim_acquire is called with the issue number before worktree entry
  Then: the zbuild:claimed label is present on the issue
  And: no stage has yet been dispatched
DSCLA-2[code]: When the claim is acquired, the claim comment on the issue names the holder; the label name contains no hostname covers: RQCLA-2, RQLAB-2
  Given: zbuild_claim_acquire succeeds for the issue
  When: the claim comment is posted
  Then: the comment body contains the run_id and machine name, or the CI run URL when GITHUB_ACTIONS=true
  And: the label name is the constant zbuild:claimed with no hostname component
DSCLA-3[code]: When zbuild:claimed is on the issue, the run exits non-zero without dispatching any stage covers: RQCLA-3
  Given: zbuild:claimed is already on the issue
  When: zbuild_claim_acquire is called
  Then: it returns 1
  And: runner.sh exits non-zero before any stage is dispatched
DSCLA-10[code]: When the run refuses to start because zbuild:claimed is on the issue, pipeline.refused.claimed is emitted to the event bus covers: RQCLA-3
  Given: zbuild:claimed is already on the issue
  When: a run is started on that issue
  Then: pipeline.refused.claimed is emitted to the event bus
DSCLA-4[code]: When zbuild_claim_acquire returns 1, _ZBUILD_CLAIM_HOLDER is set from the holder's claim comment covers: RQCLA-4
  Given: zbuild:claimed is on the issue and a claim comment with the marker exists
  When: zbuild_claim_acquire is called and finds the label present
  Then: _ZBUILD_CLAIM_HOLDER is set to the holder string extracted from the most recent claim comment body
DSCLA-9[code]: When refusing to start, the runner's output message contains the holder string from the claim comment covers: RQCLA-4
  Given: zbuild:claimed is on the issue and a claim comment with a holder string exists
  When: the runner is started on that issue
  Then: the runner's stdout or stderr output contains the holder string from the claim comment
DSCLA-5[code]: On normal pipeline completion, zbuild:claimed is removed and the claim comment is updated to finished covers: RQCLA-5
  Given: the claim was acquired at run start
  When: the pipeline exits normally (_runner_abort_trap fires with _runner_ended=true)
  Then: zbuild:claimed is absent from the issue
  And: the claim comment body shows finished status
DSCLA-6[code]: On pipeline failure, zbuild:claimed is removed and the claim comment is updated to finished covers: RQCLA-6
  Given: the claim was acquired at run start
  When: the pipeline exits due to a stage failure (_runner_abort_trap fires with failure exit)
  Then: zbuild:claimed is absent from the issue
  And: the claim comment body shows finished status
DSCLA-7[code]: On TERM signal, zbuild:claimed is removed and the claim comment is updated to finished covers: RQCLA-7
  Given: the claim was acquired at run start
  When: the runner process receives SIGTERM (_runner_signal_trap then _runner_abort_trap)
  Then: zbuild:claimed is absent from the issue
  And: the claim comment body shows finished status
DSCLA-8[code]: A run with no issue number does not check or modify zbuild:claimed covers: RQCLA-8
  Given: the run is started with --goal and no --issue (issue number is empty)
  When: zbuild_claim_acquire is called with an empty issue argument
  Then: no gh label call is made and the function returns 0
WIRING: core/pipeline/runner.sh
```
