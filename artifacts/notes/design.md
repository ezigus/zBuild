# Design notes — issue #1764 GitHub label claim

## What was read

- `core/state/issue-lock.sh` — local flock-based mutex; keyed by issue/goal; sourced
  at top of runner.sh; acquire after sidecar spawn, release in `_runner_abort_trap`.
- `core/pipeline/runner.sh` — startup sequence: sidecar spawned, issue lock, worktree entry,
  stage loop. EXIT trap = `_runner_abort_trap`. Signals → `_runner_signal_trap` → exit 1 → EXIT trap.
- `scripts/lib/run-status-comment.sh` — sidecar process, creates/updates GitHub comment via
  `<!-- zbuild-run-status run_id=... -->` marker.
- `scripts/lib/run-status-render.sh` — pure renderer; `GITHUB_ACTIONS=true` CI detection;
  CI run URL = `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`.
- `scripts/lib/identity.sh` — `zbuild_repo_slug` for owner/repo.
- `config/event-schema.json` — contains `pipeline.refused.issue_locked` and
  `pipeline.refused.run_cap`; does NOT contain `pipeline.refused.claimed`.

## Key findings

1. No `core/claim/` module exists yet.
2. The existing issue-lock is LOCAL (flock). It cannot stop a second run on a different machine.
3. The sidecar is spawned BEFORE the lock check. Claim acquisition must happen in the same window
   (after sidecar spawn, before worktree entry), consistent with the issue lock position.
4. runner.sh sources issue-lock.sh at the top and uses `declare -F` guards in the trap.
5. The design emits `pipeline.refused.claimed` but must also register it in `config/event-schema.json`
   (following the pattern of `pipeline.refused.issue_locked`). Omitting this causes
   `tests/unit/event-schema-emitted-coverage-test.sh` to fail (round 4 fix).

## Design decisions

### New file: `core/claim/claim.sh`
Minimal module, same shape as issue-lock.sh:
- `zbuild_claim_acquire <issue_number> <run_id> <slug>`: check/add `zbuild:claimed` label; create
  claim comment; set `_ZBUILD_CLAIM_HOLDER` on return 1.
- `zbuild_claim_release <issue_number> <slug>`: remove label; patch claim comment to "finished".

### Event schema registration
`pipeline.refused.claimed` must be added to `config/event-schema.json` (round 4 fix).
This is a closed set that breaks by omission: the event-schema coverage test fails if the event
is emitted but not registered.

### Claim comment as "progress comment"
A small dedicated comment on the issue (not the stage-progress status comment). It has a machine-
readable marker `<!-- zbuild-claim run_id=... -->` for the refusing run to find holder info.

### Holder string
- CI: `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}` when GITHUB_ACTIONS=true
- Local: `run_id=X machine=<hostname>`
No hostname in label name — hostname in comment body only (satisfies RQLAB-2).

### Graceful degradation
If `gh` is unavailable, unauthenticated, `NO_GITHUB=true`, or no issue number: skip claim silently.
Local flock still prevents same-machine collisions.

### Wiring
- `runner.sh` sources `core/claim/claim.sh` at the top (alongside issue-lock.sh).
- Acquisition called right after `zbuild_issue_lock_acquire` block.
- Release called in `_runner_abort_trap` right after `zbuild_issue_lock_release` block,
  using the same `declare -F` guard.

### No claim-coordinator plugin
No requirement asks for a `plugins/claim-coordinator/` plugin. The claim mechanism lives entirely
in `core/claim/claim.sh` and is wired into `runner.sh`. A plugin sourcing `core/claim/claim.sh`
was added by the coder beyond the design scope and should be removed.

### Race condition (accepted)
Check-then-label is not atomic at GitHub. Two machines racing will both succeed. Known limitation.

## SPEC codes used
DSCLA-1 through DSCLA-10:
- DSCLA-9 added in round 2: holder string in runner's refusal output (RQCLA-4 observable part).
- DSCLA-10 added in round 4: event emission `pipeline.refused.claimed` on the event bus (RQCLA-3).

## Round history
- Round 2: added DSCLA-9 to cover RQCLA-4's observable output (holder string in runner's output).
- Round 3: rewrote DSCLA-9's When/Given to describe observable pre-conditions, not internal state.
- Round 4: added step + DSCLA-10 to register `pipeline.refused.claimed` in event-schema.json.
  issue-acceptance found this gap; the coder emitted the event but the schema was not updated.
- Round 5: fixed DSCLA-10's When clause. Previous: "runner.sh processes the return value of
  zbuild_claim_acquire" (internal mechanism). Fixed: "a run is started on that issue" (observable
  action). Given and Then remain correct (observable state and observable event emission).
- Round 6: Confirmed design-draft.md already had all correct content (DSCLA-10, event-schema step).
  Answered test-author finding 1: test organization issue, not a design issue.

## Steps
1. Create `core/claim/claim.sh` with `zbuild_claim_acquire` and `zbuild_claim_release`.
2. Register `pipeline.refused.claimed` in `config/event-schema.json`.
3. Wire into `runner.sh`: source at top; call acquire after issue lock; call release in EXIT trap.

## test-author finding 1 analysis
The test file `tests/integration/teardown-repeat-signal-test.sh` stopped with exit 12 before
DSCLA-1's assertion could run on old code. The exit 12 is caused by DSCLA-9 assertions correctly
failing on old code (which is expected for [code] SPECs). The test file's early exit prevents
DSCLA-1 from being checked. This is a test organization issue — DSCLA-1 (function-level unit test
of zbuild_claim_acquire) and DSCLA-9 (integration test of runner refusal output) are logically
separate and belong in different test files. The SPEC descriptions are correctly written and
this cannot be fixed through the design.
