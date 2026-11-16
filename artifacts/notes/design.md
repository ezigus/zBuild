# Design notes — issue #1764 GitHub label claim (round 9)

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

## Changes this round (design finding fixes)

### Finding 1: DSCLA-12 uses wrong number
The preamble baseline for DSCLA is 9. The two new SPECs in the design were DSCLA-11 and DSCLA-12.
Sequential from 9 means they should be DSCLA-10 and DSCLA-11.
FIX: Renamed DSCLA-11 → DSCLA-10 (event-schema coverage SPEC) and DSCLA-12 → DSCLA-11 ([done] run-status SPEC).

### Finding 2: DSCLA-4 missing without REMOVED line
DSCLA-4 appeared in the last PASSING design (iter-1-attempt-3). It has test assertions in
`plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`.
FIX: Added REMOVED: DSCLA-4 — RQCLA-4 is fully covered by DSCLA-9; keeping a separate
assertion for the internal variable adds no additional observable coverage.
The supersedes entry for [DSCLA-4] in the claim-coordinator tests remains valid: those tests
need to be updated because the holder now comes from the run-status comment, not a separate comment.

### Finding 3: DSCLA-8 Then clause not observable
"and the run proceeds normally" is not an observable output/event/file.
FIX: Changed to:
  Then: zbuild_claim_acquire returns 0
  And: no gh label command is invoked

### Issue-acceptance finding (not a design finding):
The issue-acceptance stage flagged two code issues:
1. `pipeline.refused.claimed` not registered in event-schema.json — this is a code bug (the
   coder's implementation didn't do what step 4 of the design specifies). The design is correct:
   it has step 4 and DSCLA-10. NOT a design fix.
2. plugin.sh sourcing core/claim/claim.sh (circular dependency) — the design never asked for this.
   Added explicit note in step 1: "plugin.sh must not source core/claim/claim.sh." The design
   says claim.sh sources the plugin, not the other way around.

## SPEC codes highest used
DSCLA: 1-11 (DSCLA-4 removed via REMOVED line; DSCLA-10 = event-schema; DSCLA-11 = [done])
DSADR: 4-8 (all new this issue)

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
