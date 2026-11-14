# ADR-012 — Test Tiering and CI Gating

**Status:** Accepted; amended 2026-11-08 (tests are deterministic); amended 2026-11-11 (#2525: a test reads no clock to see how long something took); amended 2026-11-09 (#2510: a test signals only the processes it started)  ; amended 2026-11-14 (#2541: the suite sweeps the temp folders its tests left)
**Date:** 2026-05-25  
**Deciders:** zbuild core team  

## Context

zbuild Phase 0 ships with 17 test files that mix unit and integration concerns under a single CI job labeled `unit`. Both `tests/run-unit.sh` and `tests/run-all.sh` perform identical discovery. A maintainer reading the Actions tab sees `smoke ✓ unit ✓` and reasonably concludes only unit tests exist.

Problems:
1. Test taxonomy is structural fiction — no tier separation.
2. CI hides actual test scope — integration-shaped tests run under a "unit" label.
3. No e2e, golden, or mutation tiers exist.
4. No per-tier CI jobs means a regression in one tier can hide behind another.

## Decision

### Three tiers, hard definitions

| Tier | Directory | Constraint |
|---|---|---|
| unit | `tests/unit/` | Single-module, no subprocess, no FS outside `$ZBUILD_TEST_TMP`, <1s/test |
| integration | `tests/integration/` | Multi-module, mocked at process boundary, <10s/test |
| e2e | `tests/e2e/` | Full `scripts/zbuild` CLI invocation, sandbox FS, no real network |

Additional tiers: `tests/golden/` (snapshot diffs), `tests/mutation/` (doc-driven mutation records).

### Filename rule

`tests/<tier>/<area>-test.sh`

### Per-tier runner

`bash scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,lint,all}`

Output format: `<tier>: N/M passed` — parseable by CI summary step.

> **Amendment (#1129 Change C, 2026-06-29):** `lint` is now a first-class suite
> tier. `--tier all` (what `npm test` runs) runs `unit`, `integration`, `e2e`,
> `golden`, `mutation`, **and `lint`**, and the overall suite exit code reflects
> all of them — a lint failure fails the suite. The lint tier reuses
> `scripts/lib/framework-result.sh::framework_run_lint` (which runs `npm run lint`
> by default; overridable via `ZBUILD_LINT_CMD`, ADR-032/033) and emits the same
> `lint: N/M passed` summary line. This lets the simple.yaml pipeline drop its
> dedicated `lint` read-out gate (the `test` cycle member, which runs the suite,
> now also enforces lint) without losing lint enforcement — see ADR-013 note and
> ADR-040. See the **Coverage gating** note below for why coverage was NOT folded.

### Golden convention

- Snapshot files in `tests/golden/<name>.golden`
- Helper `assert_golden` in `tests/lib/golden.sh`
- `UPDATE_GOLDEN=1 bash scripts/run-tests.sh --tier golden` regenerates

### Mutation convention

- One doc per core file: `tests/mutation/<file>-mutations.md`
- Each doc: file, mutation description, expected failing test(s), result
- `scripts/run-tests.sh --tier mutation` validates doc structure (not behavior)
- CODEOWNERS or `mutation-review` label enforces re-run on changes to listed files
- **Worktree-contention robustness (#1184):** the parallel harness
  (`scripts/run-mutation.sh`) runs each mutant in a throwaway `git worktree add
  --detach HEAD`. Under N-way concurrency a checkout can be observed
  mid-materialization, so the patch's target string isn't present yet and the
  patch spuriously fails. The harness prunes stale worktrees before dispatch,
  bounded-retries the add with jittered backoff, and VERIFIES the mutated
  `## File` is present + non-empty before applying the patch.
- **Outcome classification (#1184, amended #2086):** four buckets.
  - `pass` — mutation CAUGHT.
  - `fail` — genuine coverage signal (SURVIVED mutation) or a malformed spec
    (structural / relevance / empty / no-op). Counts toward the `mutation: P/T
    passed` score and the harness exit code.
  - `infra` — NON-FATAL maintenance signal: a worktree-add failure that
    survives the retries+verify above, or a patch that failed in the parallel
    run but applies when re-applied alone (a lost race). EXCLUDED from the
    score and the exit code, surfaced on a distinct `mutation-infra:` line. It
    therefore never rolls up into test verdict=fail (via
    `framework_parse_mutation` → `test-results.json`) and is NEVER routed into
    any build-feedback loop. Enforced by
    `tests/integration/mutation-infra-nonfatal-test.sh` and
    `tests/unit/run-mutation-stale-anchor-test.sh` SPEC-2.
  - `stale` — the patch's anchor is GONE (#2086). Every patch that fails in the
    parallel run is re-applied serially, alone, to a fresh clean checkout of
    HEAD after the parallel run ends. With nothing to race, a second failure
    means the spec can never apply: it has gone inert and guards nothing. A
    stale spec is a FAILURE — it counts in the score and the exit code — and
    its `STALE <spec>` row carries the patch's own error, which names the
    missing anchor. A `mutation-stale:` line counts them, so one run shows an
    inert spec without comparing against another branch. (Before #2086 this
    case was filed as `infra`, and `memory.md` stayed inert on main while the
    tier read 23/23.) Enforced by `tests/unit/run-mutation-stale-anchor-test.sh`
    SPEC-1.

### Coverage policy

- `kcov` over unit + integration tiers
- Floor = measured baseline − 5% on first wiring PR; ratchet upward each quarter
- **Caveat:** kcov-on-bash has rough attribution under `set -e`, sourced files, subshells — treat the floor as a regression detector, not an absolute quality measure

> **Current floor (as of 2026-05-31):** 29% statement coverage on
> `core/` + `scripts/lib/` (enforced via `scripts/check-coverage.sh` and
> CI per issue #372). Target: 70%. The floor is ratcheted upward as test
> depth improves.

> **Denominator correction (#1761, 2026-08-07):** the per-file loop used to
> iterate the PS4 trace, so a file no test ever sourced contributed 0 to the
> numerator *and* 0 to the denominator — a wholly untested new file could not
> move the gate. The file set is now enumerated from disk under `core/` and
> `scripts/lib/` (scan roots deliberately exclude the frozen `legacy-DoNotUse/` import,
> whose paths also match the `/scripts/lib/` include substring). Measured
> figure moved 32.3% → 30.1%; the floor was left at 29. The arithmetic lives in
> `scripts/lib/coverage-report.py` so it is directly testable.

> **Coverage gating (#1129 Change C):** Unlike lint, coverage is **NOT** folded
> into `--tier all`. `scripts/check-coverage.sh` works by re-invoking
> `run-tests.sh --tier unit --coverage-trace` to gather an xtrace; running that
> inside `--tier all` would (a) trip the #983 re-entrancy guard (a nested
> real-tier `run-tests.sh` with no `ZBUILD_TESTS_DIR` is refused), and (b) re-run
> the entire unit tier a second time (heavy duplicate runtime). Coverage therefore
> stays enforced by its dedicated CI `coverage` job (and `bash scripts/check-coverage.sh`
> locally), not by the suite. Accordingly, simple.yaml drops its `coverage`
> read-out gate as well (the CI job remains the enforcement point). Re-folding
> coverage cleanly is a future follow-up (decouple the trace mechanism from a
> nested suite run).

### CI job graph

```
Tier 1 (parallel): smoke  lint  unit  integration  e2e-mocked  golden  mutation-lint
Tier 2 (needs Tier 1 unit+integration): coverage
Tier 3 (needs all): summary → $GITHUB_STEP_SUMMARY
```

### Empty-tier semantics

An empty tier passes green with a warning annotation to avoid bootstrap deadlock during migration.

### Real-Claude e2e

Out of scope until a budget-capped, secret-gated, `safe-to-test-e2e`-labeled workflow lands. Per-PR ($10) + daily ($25) + weekly ($100) cap via cost-ledger lookup before invocation.

## Consequences

### Positive
- CI is honest: each job label matches what it runs.
- Test regressions are caught in the correct tier job.
- Golden contracts enforce event-shape stability.
- Mutation docs prevent silent coverage drift on core files.

### Negative
- Migration cost: 17 existing tests must be moved to new tier directories.
- `kcov` on bash is imprecise — floor is a coarse safety net, not a coverage guarantee.

### Neutral
- Backward compat: `tests/run-all.sh` and `tests/run-unit.sh` delegate to the new runner; existing `npm test` / `npm run test:unit` continue to work.

## Amendment 2026-11-08 — tests are deterministic

A test depends on no remote service and on no clock. The cache-gh-actions "interrupted push" test started a push, slept 0.1s and sent KILL. On an idle machine the push took about 35ms, so it had always finished and nothing was interrupted; under load the kill landed mid-copy, the temp folder was still there when the test looked, and the test failed. It was a race in the test, not a defect in the plugin.

1. **Remote services are mocked.** Anything over the network or needing credentials — `gh`, `claude` and other model calls, `curl`, `wget` — is mocked in a test, through the test helpers (`mock_binary`, `mock_gh`, `mock_claude`, `install_envelope_mock_claude`) or a script the test writes first on `PATH`. A call by absolute path goes past the mock and is refused.
2. **Our own code is never mocked to make a test pass.** Signals sent to the engine's own processes stay real: signal handling is code under test, and the Ubuntu bugs fixed in #2490 and #2494 were found exactly that way.
3. **A signal is never timed by a sleep.** "Start it, sleep N, kill it" passes or fails with the machine's load. The process writes a marker at the point under test; the test waits for the marker, with a timeout, then signals. A poll loop waiting on a condition is this form; a sleep that only guesses when the moment has come is not. A deliberate stress test that randomises timing (the TERM-every-10ms cases in `teardown-repeat-signal-test.sh`) is marked `# determinism-ok: stress test of signal timing`.
4. **Fast, local, deterministic tools run for real**, inside the test's sandbox: git in a temporary repository, jq, the filesystem. Mocking them would test the mock (*Software Engineering at Google*, ch. 13: prefer the real implementation when it is fast and deterministic).
5. **The rule is enforced by code, not prose** (Fowler, "Eradicating Non-Determinism in Tests": no bare sleeps, test doubles for remote services, and a code check that fails the build). `scripts/lib/lint-test-determinism.sh`, in `npm run lint`, reads what each file in `tests/` and `plugins/*/tests/` runs (not its comments, strings or heredoc bodies) and refuses a remote call in a file with no mock for it, and a `kill` within three commands after a `sleep`. A line may be marked `# determinism-ok: <reason>`. Tests written before this rule are listed in `config/test-determinism-baseline.txt`, which only shrinks: each is converted to wait-for-marker, not mocked. #2501 converted the last four, so it is empty.

References: Martin Fowler, "Eradicating Non-Determinism in Tests" (martinfowler.com/articles/nonDeterminism.html); Google, hermetic tests and *Software Engineering at Google* ch. 13, "Test Doubles" (abseil.io/resources/swe-book/html/ch13.html).

## Amendment 2026-11-09 (#2510) — a test signals only the processes it started

`stage-stop-on-signal-test.sh` looked for its watchdog's `sleep 987` across the whole machine, then KILLed that sleep's parent and every child of it. With suites running side by side it found other suites' sleeps; when a sleep's parent had already exited, the parent was launchd, and `pkill -KILL -P 1` reached every process of the user whose parent is launchd.

6. **A test signals only what it started.** It never kills a pid it read from `ps` (a parent), and never looks across the machine for a fixed command line: a process it must find by its command line carries a value made for the run (the watchdog's limit), so another run's process never matches.

## Amendment 2026-11-11 (#2525) — a test reads no clock to see how long something took

`stage-time-limit-test.sh` ran a stage that slept 60 seconds, and checked that fewer than 15 went by. On #1805 run 43093018140 a busy machine made it 16, and the test failed: a test that times something passes or fails with the machine's load, like one that times a signal (3).

7. **A test reads no clock to see how long something took.** It checks what shows the thing happened — an outcome, an event, a marker the process writes — and waits on a condition, never on time. A stage that must run until stopped waits on something that never comes, not on a long sleep. `scripts/lib/lint-test-determinism.sh` refuses a read of `$SECONDS` or `date +%s` in a test. The tests that already read the clock are listed in `config/test-determinism-baseline.txt` (75 lines), which only shrinks.

## Amendment 2026-11-14 (#2541) — the suite sweeps what its tests left

A test that is killed, times out or replaces the EXIT trap leaves its temp folder; 172 had piled up on one machine. **`npm test` (`tests/run-all.sh`) ends by removing the test temp folders older than an hour** — the patterns `zbuild cleanup --tmpdirs` reads (`ZBUILD_TMPDIR_PATTERNS`), so the two never drift — says how many, and exits with the suite's own code. A newer folder may belong to a test still running elsewhere, and is kept.

## Enforced by

- Amendment 2026-11-14 (#2541: the suite sweeps the temp folders its tests left) → `tests/unit/run-all-sweep-test.sh` S1–S4

- Amendment 2026-11-11 (#2525: a test reads no clock) → `tests/unit/lint-test-determinism-test.sh` T11; `tests/integration/stage-time-limit-test.sh` S1

- Amendment 2026-11-09 (#2510: a test signals only the processes it started) → `tests/unit/tests-signal-only-their-own-test.sh` P1, P2
- Amendment 2026-11-08 (tests are deterministic) → `tests/unit/lint-test-determinism-test.sh` T1–T10 (the lint, its marks and its shrink-only baseline); `scripts/lib/lint-test-determinism.sh` runs in `npm run lint`; it reads code through `scripts/lib/shell-join.sh` (`tests/unit/shell-join-test.sh` S5–S6).
- Per-tier runner: the `total:` summary line → `tests/unit/run-tests-total-note-test.sh`; only `*-test.sh` files are run (the filename rule) → `tests/unit/run-tests-files-guard-test.sh`.
- Coverage denominator (#1761) → `tests/unit/coverage-untraced-file-test.sh`.
- The other statements above (the tier constraints, the golden and mutation conventions, the CI job graph, empty tiers) have no test yet.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| `scripts/run-tests.sh` per-tier runner (`unit` / `integration` / `e2e` / `golden` / `mutation`) | Implemented | #272 (cleanup wave) |
| All five tier directories present with tests | Implemented | confirmed by `npm test` — 23/23 unit, 31/31 integration, 6/6 e2e, 1/1 golden, 6/6 mutation |
| CI matrix: separate jobs per tier | Implemented | `.github/workflows/test.yml` |
| `kcov` bash coverage floor | Deferred → Phase 1 | floor threshold not yet set; tracking issue TBD |
| Existing `npm test` / `npm run test:unit` backward compat | Implemented | delegate to `run-tests.sh` |

## References

- ADR-001 (plugin registry — tests cover registry behavior)
- ADR-004 (redaction chokepoint — chokepoint test is tier `unit`)
- ADR-007 (golden contracts — golden tier formalizes Pillar 2)
- Issue #33 (redaction chokepoint test), #34 (goal sanitization), #70 (golden diffing), #138 (e2e workflows)
