# Plan stage notes — issue #1801 (iter-5)

## What I read

- iter-4/plan.json — 10-step plan (verdict: pass from iter-4 plan stage)
- issue-acceptance: fail — 5 findings, 2 NOT MET, 3 NOT SURE

## New findings vs. current plan

**Finding 1 — exit 143 in TERM trap (R-1/R-13 NOT MET):**
The build stage introduced an `exit 143` in lifecycle.sh's TERM trap.
This violates ADR-054 §4's {0,1} constraint and causes `dispatch-rc-guard-test` to fail.
Step 4 names the kill path and removing the hand-rolled kill-KILL, but does not name this
specific defect: the TERM trap must exit 1, not a SIGTERM-derived code.
The fix belongs in Step 4: the watchdog writes the timed_out disposition and calls
zbuild_pg_kill before returning; the TERM trap (if any remains) exits 1 and does not
write a duplicate disposition. The watchdog is the owner of the exit path on timeout.

**Finding 2 — 5400 s default not wired (R-3/R-13 NOT MET):**
`stage-timeout-precedence-test`'s isolation variant (neither template nor env set) does
not see `sleep 5400` in the fake-sleep log. This means `plugin_hook_call` is not reading
the resolved stage_timeout_s from the getter that Step 3 introduces — the 5400 s default
tier is parsed but never consumed.
Step 4 says the watchdog "arms on the run hook only" but does not say it reads from the
getter. The disconnection between Step 3 (parse/validate/expose) and Step 4 (read and arm)
is the gap.
Fix: Step 4 must explicitly state that the watchdog reads the resolved stage_timeout_s
from the getter (including the fallback to 5400 s when neither template nor env is set).

**R-10 uncertainty**: lifecycle.sh's broken state (exit 143) masks whether the
hand-rolled kill-KILL is gone. Once the TERM trap is fixed, dispatch-rc-guard-test passes
and SPEC-10 becomes verifiable. No new step needed — Step 4 already covers removing
the hand-rolled kill.

## Plan changes

- **Step 4**: Add two explicit named items:
  1. The TERM trap must not exit 143 (or any SIGTERM-derived code); the watchdog is the
     sole owner of the timeout exit path and exits 1 after writing the timed_out disposition.
  2. The watchdog reads the resolved stage_timeout_s from the getter (Step 3's output),
     applying the 5400 s default when neither template value nor ZBUILD_STAGE_TIMEOUT_S is set.

No other steps need changing.

## Acceptance coverage check (updated from iter-4)

- exit 143 TERM trap → Step 4 (newly explicit)
- 5400 s default not wired → Step 4 (newly explicit, connecting Step 3 getter to watchdog)
- Hung run hook killed at limit, every route → Steps 3, 4, 5, 7
- Whole process group dies → Steps 4, 5, 6
- Precedence: template > env > 5400 s, each tested → Step 3 (getter) + Step 4 (watchdog reads it)
- Loader rejects invalid stage_timeout_s → Step 3
- Retry and each map member get fresh timer → Step 4
- simple.yaml carries measured values; always_run uses stage_timeout_s → Step 9
- Strategies pass no flat ZBUILD_ORCH_TIMEOUT → Step 7
- orch-sequential gone, guard test, config naming it = misconfigured → Step 8
- Missing/unreadable backend = misconfigured, tested from installed tree → Step 8
- always_run and _orch_local_collect_results use zbuild_pg_kill → Steps 5, 6
- ADR-054 §9, ADR-017, ADR-011 amended with Enforced-by entries → Step 2
- npm test + lint green → all steps collectively

## Open questions (unchanged)

- SPEC-7 live-completion test: which mechanism besides the retired ZBUILD_ORCH_TIMEOUT
  collect deadline could still fire within 300 s and kill the dispatch before
  stage_timeout_s expires?

## Plan: 10 steps — Step 4 description updated to name exit-143 and 5400 s default wiring
