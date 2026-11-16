# Design notes — issue #1764 GitHub label claim (round 11)

## What was read

- `core/state/issue-lock.sh` — local flock-based mutex; keyed by issue/goal; sourced
  at top of runner.sh; acquire after sidecar spawn, release in `_runner_abort_trap`.
- `core/pipeline/runner.sh` — startup sequence: sidecar spawned, issue lock, worktree entry,
  stage loop. EXIT trap = `_runner_abort_trap`. Signals → `_runner_signal_trap` → exit 1 → EXIT trap.
- `plugins/claim-coordinator/github-labels/plugin.sh` — existing plugin with `claim_coordinator_claim`
  and `claim_coordinator_release`. Current impl uses `claimed:<machine>` labels (contradicts RQLAB-2).
- `core/claim/claim.sh` (coder-added) — thin wiring bridge that sources the plugin.
- `scripts/lib/run-status-comment.sh` — sidecar process, creates/updates GitHub comment.
- `scripts/lib/run-status-render.sh` — pure renderer; `rsc_render_header` outputs run_id marker.
  `rsc_finalize_body` changes **running** to terminal status (exists in base code).
- `config/event-schema.json` — base code has `pipeline.refused.issue_locked` and
  `pipeline.refused.run_cap`; does NOT have `pipeline.refused.claimed`.
- `docs/adr/ADR-005-claim-coordinator.md` — needs amendment per RQADR-1 through 4.
- `docs/adr/ADR-059-issue-vs-run-keying.md` — §4 describes flock as exclusivity mechanism.
  Needs amendment per RQADR-5.

## Changes this round (round 11)

### Design findings 1 & 2: RQLAB-2 unobservable from DSCLA-2's And

**Root cause**: DSCLA-2's `And: the claim label zbuild:claimed contains no hostname component`
was placed after `When: rsc_render_header is called`. Calling rsc_render_header produces rendered
markdown and touches no GitHub label — no test can observe the label name from that call.

**Fix**:
- DSCLA-1: add RQLAB-2 to covers; change `Then` to "gh is called to add exactly the label
  zbuild:claimed to the issue (no hostname component in the label name)". The test mocks `gh`
  and checks the exact argument — the label name is directly observable.
- DSCLA-2: remove RQLAB-2 from covers; remove the unobservable `And`; title now says local
  render only.
- DSCLA-12 (CI render) was already present from round 10.

## SPEC codes highest used
DSCLA: 1-12 (DSCLA-4 removed via REMOVED line; DSCLA-10 = event-schema; DSCLA-11 = [done]; DSCLA-12 = CI render case)
DSADR: 4-8 (all this issue)

## Key architectural decisions

### Run-status comment as the progress comment
Issue defines "Run-status comment" = ADR-064 comment (scripts/lib/run-status-comment.sh).
RQADR-2 says "holder is in the run-status comment." Holder added via `<!-- zbuild-holder: -->`
HTML comment in `rsc_render_header`. No separate claim comment.

### plugin.sh owns the gh calls
Claim coordinator plugin (plugins/claim-coordinator/github-labels/plugin.sh) makes all gh calls.
core/claim/claim.sh is a thin bridge only. The bridge sources the plugin; the plugin must NOT
source the bridge (would create a circular dependency).

### Graceful degradation
If gh absent, NO_GITHUB=true, or no issue number: zbuild_claim_acquire returns 0 (skip).
Local flock still serialises same-machine runs.

## UNCLEAR
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment
(scripts/lib/run-status-comment.sh), not a new comment.
