# Design notes — issue #1764 GitHub label claim (round 31)

## Changes this round (from previous rejected design)

### Finding 1 — DSADR-7 must require §1(a) and §1(b) enforcement entries in ADR-005's Enforced by

RQADR-4: "The ADR-005 amendments must include an `## Enforced by` section naming the tests that
enforce **each statement**."

RQADR-1 adds two statements to ADR-005:
- §1(a): engine calls the claim hook after the admission lock and before the first stage
- §1(b): engine calls the release hook in the EXIT path

Previous DSADR-7 only required §1(c) tests (DSCLA-3, DSCLA-9) and §2 (DSCLA-2, DSCLA-12). It
did not require any tests for §1(a) or §1(b) to appear in the Enforced by section.

DSCLA-22 is the SPEC that covers both §1(a) and §1(b): "When a stub claim coordinator is
registered and an issue-bound run executes, the stub's claim hook is called before the first
stage and its release hook is called on exit." This runs in `claim-coordinator-unit-test.sh`.

Fix:
- DSADR-7 now reads: §1 bullet names a test for each §1 statement: §1(a) → [DSCLA-22];
  §1(b) → [DSCLA-22]; §1(c) refused non-zero/no-stage/event → [DSCLA-3]; §1(c) refused
  output → [DSCLA-9]; §2 bullet → [DSCLA-2] and [DSCLA-12]
- ADR-005 step updated to add §1(a)/(§1(b)) enforcement: claim-coordinator-unit-test.sh [DSCLA-22]

### Previous round finding — teardown-repeat-signal-test.sh is wrong for DSCLA-9

DSADR-7 and the ADR-005 step named "teardown-repeat-signal-test.sh [DSCLA-9]: refused output
names holder." But teardown-repeat-signal-test.sh is the file for RQCLA-11 (second TERM
survival, enforced by DSCLA-13) — not for refused-output behavior.

Fix: replace "teardown-repeat-signal-test.sh [DSCLA-9]" with "claim-coordinator-unit-test.sh
[DSCLA-9]" in both DSADR-7 and the ADR-005 step.

Rationale: DSCLA-3 (refused: non-zero exit, no stage, event) and DSCLA-9 (refused output names
holder) are both about the refused-run path. They are naturally in the same test file,
claim-coordinator-unit-test.sh, which the design already names for DSCLA-3.

## Architecture summary

Dependency arrow: runner.sh → claim.sh → registry.sh; claim.sh → plugin_hook_call → [subshell: plugin.sh]
- plugin.sh MUST NOT source claim.sh (no circular dependency)
- claim.sh DOES NOT source plugin.sh directly
- claim.sh sources registry.sh (idempotent)
- claim.sh uses discover_plugins to find coordinator by kind at call time
- claim.sh calls plugin_hook_call for claim/release hooks
- core/ never calls gh directly for labels (RQARC-2)
- gh calls happen only inside plugins/claim-coordinator/github-labels/plugin.sh (RQARC-1)
- When issue is empty: zbuild_claim_acquire returns 0 immediately, no discover_plugins, no hook
- When _ZBUILD_CLAIM_ACQUIRED unset: zbuild_claim_release returns 0 immediately, no hook

## Load order

runner.sh: sources claim.sh before registry.sh
claim.sh sources registry.sh at its own top (idempotent guard prevents double-load)
Registry is available when claim.sh's functions are defined and when they are called.

## Requirements coverage

- RQCLA-1: DSCLA-1
- RQCLA-2: DSCLA-2, DSCLA-12
- RQCLA-3: DSCLA-3
- RQCLA-4: DSCLA-9, DSCLA-15
- RQCLA-5: DSCLA-5, DSCLA-11
- RQCLA-6: DSCLA-6, DSCLA-11, DSCLA-16
- RQCLA-7: DSCLA-7, DSCLA-11
- RQCLA-8: DSCLA-8 (acquire no-op), DSCLA-17 (release no-op)
- RQCLA-9: DSCLA-3
- RQCLA-10: DSCLA-10
- RQCLA-11: DSCLA-13
- RQCLA-12: DSCLA-1, DSCLA-18
- RQCLA-13: DSCLA-20
- RQCLA-14: DSCLA-22
- RQLAB-1: DSCLA-1
- RQLAB-2: DSCLA-1
- RQADR-1: DSADR-4
- RQADR-2: DSADR-5
- RQADR-3: DSADR-6
- RQADR-4: DSADR-7
- RQADR-5: DSADR-8
- RQDOC-1: DSCLA-14
- RQARC-1: DSCLA-18 (claim), DSCLA-20 (release)
- RQARC-2: DSCLA-19 (acquire), DSCLA-21 (release)
- RQARC-3: DSCLA-22

## SPEC id high-water marks
- DSCLA: 22 (1 removed: DSCLA-4)
- DSADR: 8

## UNCLEAR
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment (run-status-comment.sh),
not a new one.
