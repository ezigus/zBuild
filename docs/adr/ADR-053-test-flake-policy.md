# ADR-053 — Test flake remediation policy: cap + timing baseline

**Status:** Accepted (2026-08-01)
**Issue:** #1664 — child of Bugs-found EPIC #1600; siblings #1637, #1674, #1661
**Related:** [ADR-007](ADR-007-test-strategy.md) (test strategy),
[ADR-012](ADR-012-test-tiering-and-ci-gating.md) (test tiering),
[ADR-031](ADR-031-behavioral-acceptance-contract.md) (acceptance contract),
[ADR-036](ADR-036-acceptance-contract-teeth.md) (acceptance gate),
[ADR-024](ADR-024-subprocess-env-isolation.md) (subprocess env isolation)

## Context

`_ZBUILD_SERIAL_PIN` is an escape hatch in `scripts/run-tests.sh` (line 261) that routes named
integration-test files to a serial execution bucket, letting them run unloaded after the parallel
pool drains. It was added in #991 (5 entries), extended in CI lane #1047 (6 entries), and extended
again in #1425 (7 entries). Each addition had a legitimate wall-clock-budget reason, but the hatch
has no written policy, no enforcement cap, and no machine check preventing unchecked growth.

The escape hatch is a correctness trade-off: a pinned test no longer fails under CPU saturation, but
it also no longer proves it can tolerate parallel load. Left ungoverned, the pin list drifts toward
containing every timing-sensitive test, which defeats the purpose of the parallel pool and buries the
real problem (tests asserting load-sensitive wall-clock budgets that should be observable-event
assertions instead).

No timing baseline has ever been collected. `ZBUILD_TEST_TIMING_FILE` is fully implemented in
`scripts/run-tests.sh` and re-exported by `plugins/tool/test/plugin.sh`, but has never been set in
CI. Without per-file timing data there is no principled way to decide which pins are safe to
promote back to the parallel pool.

## Decision

### §1 — Offender definition

A test is a **flake offender** when it fails ≥ 1 of 10 consecutive full-tier runs under default
parallelism on an unloaded host. Single-run failures that do not reproduce at that rate are noise,
not flakes, and do not qualify for remediation.

### §2 — Remediation order

Apply these remediations in order; stop at the first one that makes the test stable:

1. **Fix hermeticity** — isolate the test from shared process state, filesystem races, and ambient
   environment variables. This is the correct fix for most apparent flakes.
2. **Observable-event assertions** — replace wall-clock sleeps and timing budgets with assertions on
   events (file creation, signal receipt, state transitions). A test that asserts
   `pipeline halts within 6s` should instead assert `SIGINT was delivered and acknowledged`.
3. **`skip_unless_capable`** — if the test requires hardware that may be absent (GPU, flock, a
   specific Bash version), skip it rather than racing.
4. **Serial pin** — as a stopgap only (see §4). Requires an open follow-up issue to remove the pin
   once hermeticity or observable-event fixes land.
5. **Never** auto-retry a failing test. Retrying hides the root cause and inflates CI cost.

### §3 — Wall-clock budget policy (deferred)

A test that pins because it asserts a tight wall-clock budget SHOULD be re-examined once a timing
baseline is available. `ZBUILD_TEST_TIMING_FILE` (wired into CI by this issue) will produce per-file
timing data after several CI runs. The baseline will identify which pins are safe to promote back to
the parallel pool (budget >> measured p99 run-time) and which need observable-event rewrites
(budget ≈ measured p99 under load). This section will be filled in once baseline data exists.

### §4 — Serial pin as stopgap

A serial pin in `_ZBUILD_SERIAL_PIN` is acceptable only when:

- The test genuinely cannot be fixed hermetically within the same PR (documented in the PR),
- An open GitHub issue tracks the follow-up fix, and
- The pin comment names the open issue.

A pin without an open tracking issue is a policy violation and must be removed or given one before
merge.

### §5 — Ratchet cap: 7 entries (ADR amendment required to raise)

`_ZBUILD_SERIAL_PIN` MUST NOT exceed **7 entries**. This cap is enforced by SPEC-17 in
`tests/unit/run-tests-parallel-test.sh`, which fails CI if an 8th entry is added.

**The cap may only be raised by amending this ADR** (update the number in §5 and in the SPEC-17
assertion) in the same PR that adds the new entry, with justification recorded here.

Current entries (7/7 as of this issue):

| File | Reason | Follow-up |
|------|--------|-----------|
| `core-pipeline-runner-test.sh` | sleep-stub + kill-mid-run timing (~193s) | §3 baseline |
| `compound-quality-pipeline-test.sh` | heavy full-pipeline timing under load | §3 baseline |
| `full-pipeline-sigint-test.sh` | asserts pipeline halts within 6–8s | §3 baseline |
| `sigint-aborts-pipeline-test.sh` | asserts total wall-clock < 4s | §3 baseline |
| `sigterm-aborts-pipeline-test.sh` | asserts wall-clock <= 5s | §3 baseline |
| `manifest-sync-similarity-test.sh` | MS5 mtime sensitive under load (CI #1047) | §3 baseline |
| `gh-automation-idempotency-log-test.sh` | unconditional sleep 1 in G8 mtime assertion (#1425) | §3 baseline |

### §6 — Timing baseline via `ZBUILD_TEST_TIMING_FILE`

`ZBUILD_TEST_TIMING_FILE` is set in the unit and integration CI jobs (`.github/workflows/test.yml`)
and the resulting files are uploaded as CI artifacts. This starts accruing per-file timing data
from the first run after this PR merges. The baseline will be used to inform §3 decisions.

## Alternatives considered

**No cap; rely on PR review.** Rejected: the three prior additions all passed review. A machine
check is the only reliable enforcement.

**Cap at 5 (the original count).** Rejected: would require immediately removing two legitimate
entries (#1047, #1425) without the timing data needed to prove they are safe to parallelize.

**Remove timing instrumentation until the baseline policy is decided.** Rejected: the
instrumentation already exists and has zero cost when unset. Activating it in CI costs nothing and
starts the clock on data collection.

## Verification

- SPEC-17 in `tests/unit/run-tests-parallel-test.sh` — static source grep counts non-comment
  entries inside `_ZBUILD_SERIAL_PIN` and asserts the count is ≤ 7. The assertion carries the ADR
  number and cap so any CI failure names the governing policy directly.
