# Design notes — issue #1764 GitHub label claim

## What was read

- `core/state/issue-lock.sh` — local flock-based mutex; keyed by issue/goal; sourced
  at top of runner.sh; acquire at ~line 2443, release in `_runner_abort_trap` at ~lines 2673-2674
- `core/pipeline/runner.sh` — startup sequence: sidecar spawned at ~2379, issue lock at ~2443,
  worktree entry at ~2466, stage loop starts much later (~3964). EXIT trap = `_runner_abort_trap`.
  Signals → `_runner_signal_trap` → exit 1 → EXIT trap.
- `scripts/lib/run-status-comment.sh` — sidecar process, creates/updates GitHub comment via
  `<!-- zbuild-run-status run_id=... -->` marker. Enabled gate: `rsc_enabled`.
- `scripts/lib/run-status-render.sh` — pure renderer; `GITHUB_ACTIONS=true` CI detection;
  CI run URL = `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`.
- `scripts/lib/identity.sh` — `zbuild_repo_slug` for owner/repo.

## Key findings

1. No `core/claim/` module exists yet.
2. The existing issue-lock is LOCAL (flock). It cannot stop a second run on a different machine.
3. The sidecar is spawned BEFORE the lock check. Claim acquisition must happen in the same window
   (after sidecar spawn, before worktree entry), consistent with the issue lock position.
4. runner.sh sources issue-lock.sh at the top (line 31) and uses `declare -F` guards in the trap.

## Design decisions

### New file: `core/claim/claim.sh`
Minimal module, same shape as issue-lock.sh:
- `zbuild_claim_acquire <issue_number> <run_id> <slug>`: check/add `zbuild:claimed` label; create
  claim comment; set `_ZBUILD_CLAIM_HOLDER` on return 1.
- `zbuild_claim_release <issue_number> <slug>`: remove label; patch claim comment to "finished".

### Claim comment as "progress comment"
A small dedicated comment on the issue (not the stage-progress status comment). It has a machine-
readable marker `<!-- zbuild-claim run_id=... -->` for the refusing run to find holder info.
This IS the "progress comment" referenced by RQCLA-2/4 — a comment that tracks this run's
activity on the issue, created at claim-time.

The existing stage-progress comment (sidecar-managed) is unchanged.

### Holder string
- CI: `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}` when GITHUB_ACTIONS=true
- Local: `run_id=X machine=<hostname>`
No hostname in label name — hostname in comment body only (satisfies RQLAB-2).

### Graceful degradation
If `gh` is unavailable, unauthenticated, `NO_GITHUB=true`, or no issue number: skip claim silently.
Local flock still prevents same-machine collisions. This is the same posture as the status comment.

### Wiring
- `runner.sh` sources `core/claim/claim.sh` at the top (alongside issue-lock.sh).
- Acquisition called right after `zbuild_issue_lock_acquire` block (~line 2452).
- Release called in `_runner_abort_trap` right after `zbuild_issue_lock_release` block (~line 2674),
  using the same `declare -F` guard.

### Race condition (accepted)
Check-then-label is not atomic at GitHub. Two machines racing will both succeed. This is a known
limitation; the requirements don't ask for a strict distributed mutex (and forbid API polling).
The mechanism prevents honest accidental overlap, not adversarial races.

## SPEC codes used
DSCLA-1 through DSCLA-9 (new code, starts at 1; DSCLA-9 added in round 2 to cover RQCLA-4's observable output — the runner's refusal message must contain the holder string, not only that _ZBUILD_CLAIM_HOLDER is set internally).

## Round 3 fix
DSCLA-9's When clause was rejected for describing the internal mechanism (runner.sh processes the return value). Fixed to describe the observable triggering action: "the runner is started on that issue" (i.e. the issue already has zbuild:claimed). The Given was also updated to describe the observable pre-condition (zbuild:claimed is on the issue; claim comment exists) rather than the internal variable state.

## Steps
1. Create `core/claim/claim.sh` with `zbuild_claim_acquire` and `zbuild_claim_release`.
2. Wire into `runner.sh`: source at top; call acquire after issue lock; call release in EXIT trap.
