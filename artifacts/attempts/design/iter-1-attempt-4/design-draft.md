# Design — GitHub label claim (#1764)

## Goal

Prevent two concurrent zBuild runs on the same issue from overlapping across machines using a
GitHub label (`zbuild:claimed`) as a soft cross-machine claim. The existing local flock
(`core/state/issue-lock.sh`) remains for intra-machine serialisation; this change adds the
inter-machine layer on top of it.

## Context

`core/state/issue-lock.sh` is a filesystem flock: effective on one host, invisible from another.
Issue #1764 asks for a GitHub label that any run can see before it starts. The run-status sidecar
already posts a progress comment on the issue (ADR-064, `scripts/lib/run-status-comment.sh`);
the holder string goes into that comment, satisfying RQADR-2 without a separate claim comment.

## Decision

**Run-status comment as the progress comment.** `rsc_render_header` (in `scripts/lib/run-status-render.sh`)
adds a machine-readable `<!-- zbuild-holder: ... -->` HTML comment immediately after the
`<!-- zbuild-run-status run_id=... -->` marker line. Format:
- CI (`GITHUB_ACTIONS=true`): `<!-- zbuild-holder: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID} -->`
- Local: `<!-- zbuild-holder: run_id=<run_id> machine=<hostname> -->`

This makes the holder extractable by any run searching the issue's comments for the
`<!-- zbuild-run-status run_id=` marker prefix.

**New `core/claim/claim.sh`** (standalone — no plugin dependency):
- `zbuild_claim_acquire <issue>`: skip if issue is empty; check `zbuild:claimed` via `gh issue view`; if absent, add it and return 0; if present, search issue comments for the most recent run-status comment and extract `_ZBUILD_CLAIM_HOLDER` from the `<!-- zbuild-holder: -->` field, then return 1. All `gh` failures are advisory (return 0 — local flock still serialises).
- `zbuild_claim_release <issue>`: remove `zbuild:claimed` label (advisory). Run-status comment finalization is existing sidecar behavior; no separate comment update needed.

**Wire into `core/pipeline/runner.sh`**: source at top; call `zbuild_claim_acquire` right after `zbuild_issue_lock_acquire` succeeds; on return 1, emit `pipeline.refused.claimed`, print holder, return 1 (same shape as issue-lock refusal); call `zbuild_claim_release` in `_runner_abort_trap` after `zbuild_issue_lock_release`, using `declare -F` guard.

**Register `pipeline.refused.claimed`** in `config/event-schema.json` (follows pattern of `pipeline.refused.issue_locked`).

**Amend ADR-005** with RQADR-1 through RQADR-4 (engine calls coordinator, single label, holder in run-status comment, stale content corrections, Enforced by section).

**Amend ADR-059 §4** noting that cross-machine exclusion is the coordinator's job; the flock stays for intra-machine (RQADR-5).

The label name `zbuild:claimed` contains no hostname. Holder string contains machine name (local) or CI URL — in the comment body, not the label (RQLAB-2). Check-then-label is not atomic at GitHub; two racing machines may both succeed. Known limitation; a strict mutex is out of scope (RQMECH-1, RQMECH-2).

UNCLEAR: RQADR-2 | The requirement says "the holder is in the run-status comment" (ADR-064 comment, defined in terms). The previous design used a separate "claim comment". | Assumed: use the existing run-status comment; `<!-- zbuild-holder: -->` is added to its header; the previous design's "claim comment" concept is removed.

```steps
- Edit scripts/lib/run-status-render.sh: add <!-- zbuild-holder: CI_URL --> (CI) or <!-- zbuild-holder: run_id=X machine=H --> (local) in rsc_render_header after the run_id marker printf | areas: scripts/lib/run-status-render.sh
- Create core/claim/claim.sh: zbuild_claim_acquire and zbuild_claim_release; standalone (no plugin source); acquire checks/adds zbuild:claimed; on failure reads holder from run-status comment via gh api; graceful degradation gates (no issue, NO_GITHUB, gh absent/unauthed) | areas: core/claim/claim.sh
- Register pipeline.refused.claimed in config/event-schema.json following the pattern of pipeline.refused.issue_locked | areas: config/event-schema.json
- Wire core/claim/claim.sh into runner.sh: source at top; call zbuild_claim_acquire after zbuild_issue_lock_acquire; emit event + print holder + return 1 on refusal; call zbuild_claim_release in _runner_abort_trap with declare -F guard | areas: core/pipeline/runner.sh
- Amend docs/adr/ADR-005-claim-coordinator.md: add §1 (engine calls claim/release), §2 (single zbuild:claimed label; holder in run-status comment), §3 (stale content: selection not from config/zbuild.yaml; engine now has built-in mechanism), and ## Enforced by section naming tests per statement | areas: docs/adr/ADR-005-claim-coordinator.md
- Amend docs/adr/ADR-059-issue-vs-run-keying.md §4: note that cross-machine exclusion is the claim coordinator's job and the admission flock stays for intra-machine serialisation | areas: docs/adr/ADR-059-issue-vs-run-keying.md
```

```acceptance
DSCLA-1[code]: When an issue-bound run starts and zbuild:claimed is absent, the label is added to the issue before the first stage dispatches covers: RQCLA-1, RQLAB-1
  Given: a run is started with an issue number; zbuild:claimed is not on the issue
  When: zbuild_claim_acquire is called with the issue number before worktree entry
  Then: the zbuild:claimed label is present on the issue
  And: no stage has yet been dispatched
DSCLA-2[code]: When the claim is acquired, the run-status comment contains the holder string in a machine-readable field; the label name contains no hostname covers: RQCLA-2, RQLAB-2
  Given: zbuild_claim_acquire succeeds for the issue
  When: the run-status comment is examined
  Then: it contains a <!-- zbuild-holder: --> HTML comment with the run_id and machine name (for local runs), or the CI run URL (for CI runs)
  And: the label name is the constant zbuild:claimed with no hostname component
DSCLA-3[code]: When zbuild:claimed is on the issue, zbuild_claim_acquire returns 1 and runner.sh exits non-zero without dispatching any stage covers: RQCLA-3
  Given: zbuild:claimed is already on the issue
  When: zbuild_claim_acquire is called
  Then: it returns 1
  And: runner.sh exits non-zero before any stage is dispatched
DSCLA-4[code]: When zbuild_claim_acquire returns 1, _ZBUILD_CLAIM_HOLDER is set from the holder's run-status comment covers: RQCLA-4
  Given: zbuild:claimed is on the issue and the holder's run-status comment contains a <!-- zbuild-holder: --> field
  When: zbuild_claim_acquire is called and finds the label present
  Then: _ZBUILD_CLAIM_HOLDER is set to the holder string extracted from the <!-- zbuild-holder: --> field in the most recent run-status comment
DSCLA-9[code]: When refusing to start, the runner's output message contains the holder string from the run-status comment covers: RQCLA-4
  Given: zbuild:claimed is on the issue and the holder's run-status comment contains a <!-- zbuild-holder: --> field
  When: the runner is started on that issue
  Then: the runner's stdout or stderr output contains the holder string extracted from the run-status comment
DSCLA-5[code]: On normal pipeline completion, zbuild:claimed is removed from the issue covers: RQCLA-5
  Given: the claim was acquired at run start
  When: the pipeline exits normally (_runner_abort_trap fires with _runner_ended=true)
  Then: zbuild:claimed is absent from the issue
DSCLA-6[code]: On pipeline failure, zbuild:claimed is removed from the issue covers: RQCLA-6
  Given: the claim was acquired at run start
  When: the pipeline exits due to a stage failure (_runner_abort_trap fires with failure exit)
  Then: zbuild:claimed is absent from the issue
DSCLA-7[code]: On TERM signal, zbuild:claimed is removed from the issue covers: RQCLA-7
  Given: the claim was acquired at run start
  When: the runner process receives SIGTERM (_runner_signal_trap then _runner_abort_trap)
  Then: zbuild:claimed is absent from the issue
DSCLA-8[code]: A run with no issue number does not check or modify zbuild:claimed covers: RQCLA-8
  Given: the run is started with --goal and no --issue (issue number is empty)
  When: zbuild_claim_acquire is called with an empty issue argument
  Then: no gh label call is made and the function returns 0
DSCLA-10[code]: When the run refuses to start because zbuild:claimed is on the issue, pipeline.refused.claimed is emitted to the event bus covers: RQCLA-9
  Given: zbuild:claimed is already on the issue
  When: a run is started on that issue
  Then: pipeline.refused.claimed is emitted to the event bus
DSCLA-11[code]: The pipeline.refused.claimed event passes the event-schema coverage check covers: RQCLA-10
  Given: pipeline.refused.claimed is emitted in runner.sh when zbuild:claimed is present
  When: the event-schema emitted coverage check runs
  Then: the check does not fail on pipeline.refused.claimed as an unregistered event
DSCLA-12[done]: The run-status comment shows terminal status (not "running") when the runner exits on any path covers: RQCLA-5, RQCLA-6, RQCLA-7
  When: the runner exits on any path (normal, failure, or signal)
  Then: the run-status comment's status header is not "running"
  evidence: scripts/lib/run-status-render.sh | rsc_finalize_body() {
DSADR-4[doc]: ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path covers: RQADR-1
DSADR-5[doc]: ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment covers: RQADR-2
DSADR-6[doc]: ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism covers: RQADR-3
DSADR-7[doc]: ADR-005 has an ## Enforced by section naming the test or lint that enforces each statement covers: RQADR-4
DSADR-8[doc]: ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation covers: RQADR-5
WIRING: core/pipeline/runner.sh
```

```supersedes
plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh [DSCLA-2]: assertion "gh issue comment was called" and "comment contains run_id/machine name" — holder is now in the run-status comment via <!-- zbuild-holder: -->, not a separate claim comment posted by zbuild_claim_acquire
plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh [DSCLA-4]: assertion "_ZBUILD_CLAIM_HOLDER contains holder string from claim comment" — holder is now extracted from the run-status comment's <!-- zbuild-holder: --> field, not a separate claim comment
tests/integration/teardown-repeat-signal-test.sh [DSCLA-5]: assertion "claim comment body shows finished status" checks ZBUILD_CLAIM_STORE/comment.txt — no claim comment in the new design; the progress comment is the run-status comment, finalized by the existing sidecar (DSCLA-12)
tests/integration/teardown-repeat-signal-test.sh [DSCLA-6]: same — "claim comment body shows finished status after failure exit" is obsolete
tests/integration/teardown-repeat-signal-test.sh [DSCLA-7]: same — "claim comment body shows finished status after TERM signal" is obsolete
tests/integration/teardown-repeat-signal-test.sh [DSCLA-9]: pre-seeds ZBUILD_CLAIM_STORE/$issue/holder.txt with the holder string — now the holder must be in a mock run-status comment with <!-- zbuild-holder: --> field for zbuild_claim_acquire to read
```
