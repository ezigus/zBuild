# ADR-053 — Test Flake Policy: Serial-Pin Cap + Timing Baseline

**Status:** Accepted
**Date:** 2026-08-02
**Issues:** #1637, #1600, #1425, #1047

## Context

Four separate CI investigations documented the serial-pin creep pattern:

- **#1047** — `manifest-sync-similarity-test.sh` flaked on a 2-core CI runner even after being
  pinned to the serial bucket; the serial pin ran *after* the parallel pool and still raced a
  saturated CPU. Fixed by running pins *before* the pool. Lesson: serial pinning alone is not
  a root-cause fix, only a scheduling change.
- **#1425** — `gh-automation-idempotency-log-test.sh` (unit tier) has an unconditional `sleep 1`
  in its G8 mtime assertion. It flaked when the unit pool saturated CPU on the CI 2-core runner.
  Pinned to serial bucket as stopgap; root cause (hardcoded sleep) still open.
- **#1600** — recurring CI flakes traced to wall-clock-sensitive assertions under a loaded parallel
  pool. Pattern: test asserts a budget of N seconds; load stretches actual elapsed past N. Root
  fix is making the budget load-tolerant (mock clock or load-scaled factor), not pinning.
- **#1637** — CI flakes from tests asserting signal-delivery latency. Same category: tight
  wall-clock budget fails when CPU is saturated. Serial pin deferred the failure; root cause open.

As of this ADR, `_ZBUILD_SERIAL_PIN` in `scripts/run-tests.sh` holds **7 entries**. No assertion
enforced a cap, creating a low-friction path to accumulate serial pins indefinitely — each one
a deferred root-cause fix and a growing drag on CI wall-clock.

`ZBUILD_TEST_TIMING_FILE` instrumentation exists in the runner (#1058 Phase A) but the CI direct
test jobs (`test.yml` unit and integration steps) never set the variable, so no timing baseline
accumulates on the main branch to inform the load-tolerance follow-up work.

## §1 — Flake offender definition

A test file is a **flake offender** when it produces ≥1 failure in 10 consecutive full-tier
runs on a committed tree with no intervening source change. Intermittent failures on a WIP
branch are not offenders under this definition; they must reproduce on a clean committed tree.

## §2 — Ordered default remediation

Apply in order; move to the next step only when the prior step is proven insufficient:

1. **Fix hermeticity.** Shared state, fixed temp paths, and real-repo writes are the most
   common flake cause. Audit via the A3d hermeticity checklist before any timing work.
2. **Replace wall-clock with observable-event assertions.** Prefer `wait`-style event
   observation (process exits, sentinel files) over `sleep`-based timing. If a budget is
   genuinely load-dependent, scale it by a CPU-load factor rather than hardcoding.
3. **`skip_unless_capable`.** If the test requires resources (a 4-core host, a real network)
   that are structurally absent on some runners, gate it with `skip_unless_capable` rather
   than let it flake.
4. **Serial-pin as last resort.** If steps 1–3 are impractical (see §3), pin to the serial
   bucket with a reason comment and an open issue tracking the root-cause fix. **Never
   auto-retry** — a retry masks a real flake and delays root-cause investigation.

## §3 — Serial-pin as stopgap

A serial pin is a scheduling change, not a fix. It must be:

- Added to `_ZBUILD_SERIAL_PIN` in `scripts/run-tests.sh` with a **one-line reason comment**.
- Accompanied by an **open GitHub issue** tracking the root-cause fix (load-tolerant budget,
  mock clock, hermeticity repair). The issue link appears in the reason comment.

The 7 current pins and their open issues:

| File | Reason | Issue |
|------|--------|-------|
| `core-pipeline-runner-test.sh` | sleep-stub + kill-mid-run timing (~193 s long-pole) | follow-up |
| `compound-quality-pipeline-test.sh` | heavy full-pipeline timing under load | follow-up |
| `full-pipeline-sigint-test.sh` | asserts pipeline halts within 6–8 s | follow-up |
| `sigint-aborts-pipeline-test.sh` | asserts total wall-clock < 4 s | follow-up |
| `sigterm-aborts-pipeline-test.sh` | asserts wall-clock ≤ 5 s | follow-up |
| `manifest-sync-similarity-test.sh` | MS5 mtime assertion, load-sensitive (#1047) | #1047 |
| `gh-automation-idempotency-log-test.sh` | `sleep 1` in G8 mtime assertion, unit pool (#1425) | #1425 |

## §4 — Ratchet cap of 7 entries

The `_ZBUILD_SERIAL_PIN` array is capped at **7 entries**. Adding an 8th entry without removing
an existing one or amending this ADR is a policy violation. SPEC-17 in
`tests/unit/run-tests-parallel-test.sh` mechanises this cap: it counts non-comment, non-blank
lines in the array and asserts the count is ≤ 7. The count-check fails CI before a PR can merge
with an uncapped 8th pin.

To raise the cap: amend this ADR in the same PR that adds the pin, stating why steps 1–3 of §2
are impractical for the new offender. A cap raise is not routine — it requires justification.

## §5 — Timing budget deferred pending §2 baseline data

`ZBUILD_TEST_TIMING_FILE` is now wired into the CI unit and integration steps (SPEC-18, SPEC-19)
so per-file wall-clock data accumulates on the main branch. This baseline is a prerequisite for
the load-tolerance follow-up (§2 step 2): without real CI timing data, any proposed
`sleep`-to-event or mock-clock conversion is speculative.

The analysis and threshold decisions for converting pinned tests to load-tolerant assertions are
**deferred to a follow-up issue** once at least 10 CI runs of baseline data exist.

## Implementation Notes

**Seams.**

- `scripts/run-tests.sh` — `_ZBUILD_SERIAL_PIN` array: the authoritative list of serially-pinned
  test files. Each entry must have a one-line reason comment and an open issue link (§3).
- `tests/unit/run-tests-parallel-test.sh` — SPEC-17 assertion counts non-comment, non-blank
  entries in `_ZBUILD_SERIAL_PIN` and asserts the count is ≤ 7 (§4 ratchet cap).
- `.github/workflows/test.yml` — `ZBUILD_TEST_TIMING_FILE` env var wired into both the unit and
  integration run steps; timing logs uploaded as CI artifacts (SPEC-18, SPEC-19).
