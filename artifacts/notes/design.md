# Design notes — issue #1801 (seventh refinement — judge pass)

## What I read

- design.md acceptance block (lines 167–205): authoritative design artifact
- notes/design.md from previous pass (sixth refinement)

## Key discrepancy found

The system-message ACCEPTANCE block and design.md diverge on two SPECs:

### SPEC-15

design.md line 182 (actual):
  SPEC-15: grep -rl for orch-sequential, ZBUILD_ORCH_TIMEOUT, router.timeout_s
  (THREE patterns only)

system-message (what I was given to judge):
  SPEC-15: grep -rl for orch-sequential, ZBUILD_ORCH_TIMEOUT, router.timeout_s,
           and kill.*_ar_pid — four patterns total

The sixth-refinement notes claimed this fix was applied ("SPEC-15 updated to
include the fourth grep pattern"). design.md was NOT actually updated.

### SPEC-2

design.md line 169 (actual): "exits with status 143"
system-message: "exits with status 1"

The fifth-refinement notes claimed exit 143 → exit 1 was applied to design.md.
It was not. design.md still says exit 143 in SPEC-2 AND in the pseudocode (line 32)
and rationale (line 39), and in the supersedes block (line 209).

## Judgment basis

My instructions explicitly say: "ACCEPTANCE — the SPEC sentences the design commits to"
and present those sentences directly. I judge the ACCEPTANCE as given in the system
message. Those sentences DO cover all 13 requirements.

## Requirement-by-requirement verdict

R-1: SPEC-1 (per-dispatch watchdog on every route, every backend, timed_out naming
     stage/limit, AWK-verified always_run), SPEC-12 (timed_out valid disposition),
     SPEC-18 (plugin.run.timed_out in event-schema.json) → COVERED
     "Regression test reddens at merge-base" = verification requirement, excluded.

R-2: SPEC-2 [system prompt: exit 1] (set -m, TERM trap kills process group,
     children not orphaned), SPEC-13 (zbuild_pg_kill exists, handles TERM+10s) → COVERED

R-3: SPEC-3 (template > ZBUILD_STAGE_TIMEOUT_S > 5400s; 5400s isolation test) → COVERED

R-4: SPEC-4 (loader rejects below router.timeout_s and non-integer) → COVERED

R-5: SPEC-5 (watchdog inside plugin_hook_call, fresh timer per retry/map member) → COVERED

R-6: SPEC-6 (_runner_dispatch_always_run reads _TPL_STAGE_TIMEOUT_S_<stage> not
     router.timeout_s; simple.yaml stage_timeout_s for every stage, release=30,
     persist=120) → COVERED

R-7: SPEC-7 (ZBUILD_ORCH_TIMEOUT absent from all 3 strategy files; 310s hook inside
     stage_timeout_s completes with exit 0) → COVERED

R-8: SPEC-8 (orch-sequential directory absent, no file outside docs/adr/ names it,
     sequential config ends misconfigured), SPEC-14 (contract.sh defaults to
     bash-parallel), SPEC-17 (every orch-sequential fixture test updated, guard
     enforces mechanically) → COVERED

R-9: SPEC-9 (both error cases fail as misconfigured naming backend), SPEC-19
     (installed-tree variant via install.sh temp dir) → COVERED

R-10: SPEC-10 (plugin_hook_call uses zbuild_pg_kill, _runner_dispatch_always_run
      uses zbuild_pg_kill, _orch_local_collect_results uses zbuild_pg_kill) → COVERED

R-11: SPEC-15 [system prompt: four patterns including kill.*_ar_pid] → COVERED
      (This gap was flagged in the previous design run. System-message SPEC-15 has the
      fix. design.md was NOT updated to match — a design artifact inconsistency noted
      here but judged against the ACCEPTANCE as given.)

R-12: SPEC-11 (ADR-054 §9, ADR-017, ADR-011 gain Enforced by sections; both removed
      from adr-enforcement-baseline.txt) → COVERED

R-13: SPEC-16 (npm test and npm run lint pass after all code changes applied) → COVERED
      Note: design.md SPEC-2 says exit 143, which breaks dispatch-rc-guard-test. This
      internal contradiction between SPEC-2 and SPEC-16 is a design artifact defect,
      but R-13 IS covered by SPEC-16's sentence. The build stage must reconcile it.

## Verdict

COVERED — all 13 requirements are addressed by the ACCEPTANCE sentences.

## Open artifact defects (not design coverage gaps, but worth noting)

1. design.md SPEC-15 still has 3 patterns (not 4) — inconsistent with system-message ACCEPTANCE
2. design.md SPEC-2 still says "exit 143" — inconsistent with system-message ACCEPTANCE
3. design.md line 32 pseudocode: exit 143 (should be exit 1 per fifth refinement notes)
4. design.md line 39 rationale: says exit 143 needed to prevent bash resuming (incorrect reasoning)
5. design.md supersedes block (line 209): "exits 143" (should be "exits 1")

These are build-stage concerns. The system-message ACCEPTANCE sentences (which I judge)
have the corrected versions and cover all requirements.
