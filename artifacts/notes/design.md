# Design notes — issue #1764 GitHub label claim (round 20)

## Changes this round: lens findings addressed

The review_lenses stage failed on security, red-team, correctness, scope, and sre lenses.
All lens-*-design-result.json files said "pass / no findings the design must fix" — but the
judged.json files contained code findings, some of which were design gaps. Changes made:

### Findings addressed

**1. plugin.sh sources claim.sh (scope/sre/red-team HIGH)**
Code added `source core/claim/claim.sh` to plugin.sh despite design prohibiting it.
Fixed: Decision section now explicitly says plugin.sh MUST NOT contain any `source` of
claim.sh; explains the circular load. Step 1 now says "ensure NO `source` of core/claim/claim.sh
appears anywhere in plugin.sh."

**2. claim_coordinator_claim still uses `claimed:<machine>` (correctness/scope MEDIUM)**
Code kept `local our_label="claimed:${machine}"` despite step saying to change it.
Fixed: Decision section now says "Delete the `local our_label=...` line and all per-machine
label logic from both functions; replace with `local label="zbuild:claimed"`."
Step 1 updated with the same explicit instruction.

**3. zbuild_claim_release doesn't unset _ZBUILD_CLAIM_ACQUIRED (correctness/scope/sre)**
Design already said to do this, code didn't. Fixed: Decision section now says "MUST call
`unset _ZBUILD_CLAIM_ACQUIRED` BEFORE calling `_ccgl_remove_label`." Step 4 updated with MUST.

**4. Early-failure paths after claim acquire don't call release (red-team HIGH)**
After zbuild_claim_acquire succeeds, _runner_enter_worktree and zbuild_run_branch_setup
failure paths only call `zbuild_run_cap_release || true`, not `zbuild_claim_release || true`.
EXIT trap is installed much later so it won't fire on these paths.
Fixed: Decision section now has an explicit paragraph about this gap. Step 7 updated to add
`zbuild_claim_release || true` and `zbuild_issue_lock_release || true` to both paths.
New SPEC DSCLA-16[code] added (covers RQCLA-6).

**5. Holder string sanitization (security/red-team MEDIUM)**
_ccgl_read_holder extracts holder from GitHub comment. If holder contains \n or ANSI codes,
error() (which uses echo -e) interprets them → log injection.
Fixed: Decision section now says "sanitize the extracted holder string (strip ANSI escape codes
and literal backslash sequences via `printf '%s'` or `sed`) before storing in _ZBUILD_CLAIM_HOLDER."
Decision also says use `printf '%s\n'` not `error()` when printing holder on refusal.
Steps 4 and 7 updated. New SPEC DSCLA-15[code] added (covers RQCLA-4, alongside DSCLA-9).

**6. SRE observability on graceful degradation (sre MEDIUM)**
Code silently returns 0 on backend error with no log. Design said "graceful" but no log.
Fixed: Decision section now says "log a warning to stderr so the skip is visible."
Step 4 updated.

**7. SRE test finding: DSCLA-9 fixture is hand-written (sre MEDIUM, fix: test)**
Tagged "fix: test" in the SRE result. Not a design gap — the design SPEC correctly specifies
Given/When/Then. The test author must rewrite the fixture to use rsc_render_header.
Answered: "not mine."

## SPEC additions this round
- DSCLA-15[code]: holder sanitized before printing (covers RQCLA-4, alongside DSCLA-9)
- DSCLA-16[code]: early-failure paths release claim before returning (covers RQCLA-6, alongside DSCLA-6)

## SPEC code highest used
- DSCLA: 1-16 (DSCLA-4 REMOVED; DSCLA-10=[code]; DSCLA-11=[done]; DSCLA-12=CI render;
  DSCLA-13=second TERM; DSCLA-14=README doc; DSCLA-15=sanitization; DSCLA-16=early-failure)
- DSADR: 4-8

## Requirements coverage (complete)
- RQCLA-1: DSCLA-1
- RQCLA-2: DSCLA-2, DSCLA-12
- RQCLA-3: DSCLA-3
- RQCLA-4: DSCLA-9, DSCLA-15
- RQCLA-5: DSCLA-5, DSCLA-11
- RQCLA-6: DSCLA-6, DSCLA-11, DSCLA-16
- RQCLA-7: DSCLA-7, DSCLA-11
- RQCLA-8: DSCLA-8
- RQCLA-9: DSCLA-3
- RQCLA-10: DSCLA-10
- RQCLA-11: DSCLA-13
- RQLAB-1: DSCLA-1
- RQLAB-2: DSCLA-1
- RQADR-1: DSADR-4
- RQADR-2: DSADR-5
- RQADR-3: DSADR-6
- RQADR-4: DSADR-7
- RQADR-5: DSADR-8
- RQDOC-1: DSCLA-14

## Key architectural decisions (unchanged from prior rounds)

Dependency direction: runner.sh -> claim.sh -> plugin.sh (one direction only).
Path resolution: claim.sh uses $_ZBUILD_ROOT (set by runner.sh). No $(cd ...) subshell.
Holder string: Local: run_id=X machine=${HOSTNAME} (bash built-in, no fork).
  CI: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}.
  Built before sidecar spawn so sidecar inherits via environment.
RQCLA-11: _runner_abort_trap `trap '' INT TERM` guard blocks SIGTERM re-entry.
  zbuild_claim_release unsets _ZBUILD_CLAIM_ACQUIRED before gh call (no-op on re-entry).
Run-status comment: ADR-064 comment (scripts/lib/run-status-comment.sh), not a new one.
  Holder added via <!-- zbuild-holder: --> HTML comment in rsc_render_header.

## UNCLEAR (unchanged)
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment, not a new one.
