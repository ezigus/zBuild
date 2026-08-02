# Integration-test hermeticity audit (issue #988, EPIC #982)

Report-only deliverable for **A3a (#988)**. Drives the fix issues **A3b (#989)** and **A3c (#990)**
and the tier-enable **A3d (#991)**. No behavior change ships in #988.

Produced by three parallel audit lenses (state/events/HOME · temp/ports/fixed-paths ·
git/worktree/global-config/process), every finding then re-verified by direct grep.

## Method + baseline

`scripts/lib/test-helpers.sh` `setup_test_env()` (line ~224) gives **each test** a unique per-test
`TEST_TEMP_DIR` — created via `mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX"` — and exports
`HOME="$TEST_TEMP_DIR/home"` and `PATH="$TEST_TEMP_DIR/bin:$PATH"`. **146 of 148**
`tests/integration/*.sh` call it.

Two precision points the audit relies on (verified against the harness, corrected per #1005 review):
- `setup_test_env` **does not export `TMPDIR`** — it only *reads* it to choose where `TEST_TEMP_DIR`
  lives. A process that calls bare `mktemp` still lands under the *real* `TMPDIR` (or `/tmp`), not
  `TEST_TEMP_DIR`. That's safe for *collision* purposes (mktemp yields unique names) but means a **fixed**
  path like `/tmp/mark` is genuinely shared.
- The `mktemp` **shim is macOS-only** (`uname -s == Darwin`, line ~47). On the Linux CI runners it is
  **absent**, so the fixed-path fallbacks below (`/tmp/mark`, `/tmp/gh-calls.log`) are the actual CI
  exposure if their `*_FILE` env var is ever unset — not merely a latent macOS concern.

**Headline:** the integration suite is *largely already parallel-safe*, because the planned runner runs
each test file as its own subprocess (`scripts/run-tests.sh` per-file loop) and `setup_test_env`
isolates HOME/PATH/state per subprocess. The findings below are therefore mostly **latent** — fixed
shared values that collide only if HOME/env isolation is bypassed (a shared-worktree or env-stripping
runner). They are cheap to harden and should land before A3d flips the tier to parallel.

**Whole classes confirmed clean (grep-verified):** `git worktree` — none; `git config --global` —
none; ports/sockets/named pipes — none; fd3/`exec 3>` — process-local sentinel files; pool dirs/PIDs —
under `TEST_TEMP_DIR` with `$$`. **So A3c (#990) as originally scoped (worktree/port/global-git) has
nothing to fix — it should be repurposed to the real-repo-write + temp-path/cwd offenders below.**

**One class is NOT clean (adversarial review C1/C2):** real-repo writes under `$REPO_ROOT` — see the
*Real-repo `$REPO_ROOT` writes* table below. This is the only **active** (not merely latent) hazard in
the suite: it writes to the live working tree regardless of HOME isolation.

## Offenders by class → fix owner

### Real-repo `$REPO_ROOT` writes  → A3c (#990, repurposed)  ⚠ ACTIVE
| Sev | File(s) | Issue | Fix |
|-----|---------|-------|-----|
| HIGH (active) | `deferred-tracker-integration-test.sh` (T10, ~lines 355–364) | T10 runs `bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply`, which `touch`es `DRIFT_SENTINEL="$REPO_ROOT/.deferred-drift"` (`scripts/deferred-tracker.sh:42,622`) — a write to the **live working tree**, independent of HOME isolation. The test `rm -f`s the sentinel around the assertion but has **no `trap`**, so a failure between the `--apply` and the final `rm -f` leaves `.deferred-drift` in the real repo, where it collides with any concurrent run and can poison the next `deferred-tracker` invocation. This is the only finding that bites today, not just under a shared-HOME runner. | Point the sentinel at a sandbox: run the script with `ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"` (or equivalent) so `DRIFT_SENTINEL` lands under `TEST_TEMP_DIR`; **add `trap 'rm -f "$REPO_ROOT/.deferred-drift"' EXIT`** as belt-and-suspenders. Verify `scripts/deferred-tracker.sh` honors an overridable repo root before relying on the env approach. |

### State / RUN_ID  → A3b (#989)
| Sev | File(s) | Issue | Fix |
|-----|---------|-------|-----|
| HIGH* | `build-prompt-includes-branch-state-end-to-end-test.sh:166`, `runner-exports-state-dir-test.sh:90` | Both invoke the runner with fixed `ZBUILD_RUN_ID="run-618"` → both write `$HOME/.zbuild/state/runs/run-618/`. Hermetic today (each test's own HOME) but collides if a parallel runner ever shares HOME. | `ZBUILD_RUN_ID="run-618-$$"` in both; recompute `EXPECTED_STATE_DIR` in `runner-exports-state-dir-test.sh`. |
| LOW (defensive) | `stage-io-banner-split-test.sh`, `stage-io-channel-split-test.sh`, `route-fresh-shell-test.sh`, `core-router-route-test.sh` (C6), `stage-io-capture-test.sh`, `stage-io-command-capture-test.sh`, `stage-io-gh-comment-ansi-strip-test.sh` | Fixed `ZBUILD_RUN_ID` values; cosmetic today (writes land under per-test HOME/`TEST_TEMP_DIR`). | Append `$$` to RUN_IDs as defense-in-depth before A3d. |

\* "HIGH" = highest *in the RUN_ID class*, but conditional on a shared-HOME runner; not an active
collision under per-subprocess execution. (The genuinely active write is the `$REPO_ROOT` one above.)

\*\* **Asymmetry (review M6):** `build-prompt-includes-branch-state-end-to-end-test.sh:166` already pins
`HOME="$HOME_DIR"` inline on the `env` invocation, so its `run-618` write is doubly contained;
`runner-exports-state-dir-test.sh:90` relies solely on `setup_test_env`'s exported HOME. Both still need
the `run-618-$$` fix, but the residual risk is asymmetric — the latter is the one to prioritize.

### Temp-path fallbacks / CWD  → A3c (#990, repurposed)
| Sev | File(s) | Issue | Fix |
|-----|---------|-------|-----|
| ~~MED~~ FIXED (#1019) | 9 mock-`claude` tests: `loop-auto-terminate-no-progress`, `router-loop-preserves-error-artifacts`, `build-test-cycle-progress`, `build-no-stash-flow`, `router-loop-rc124-honors-sentinel`, `loop-already-done-emits-complete`, `build-changed-files-summary`, `build-banner-llm-prompt-visible`, `build-loop-banner` | Mock `claude` body baked `mark="${MARK_FILE:-/tmp/mark}"` — a shared fixed fallback reached if `MARK_FILE` isn't inherited (env-strip / refactor). | Fixed in A3c-2 (#1019): interpolated the resolved path into the mock body at write time (`mark="$MARK_FILE"`); added `[SPEC-1]` non-empty guard at setup; dropped the `/tmp/mark` fallback. |
| MED | `deferred-tracker-integration-test.sh:30` | Mock `gh` bakes `GH_CALLS_LOG="${GH_CALLS_LOG:-/tmp/gh-calls.log}"` — same shared-fallback pattern. | Same: bake `$TEST_TEMP_DIR` into the mock body; no `/tmp` fallback. |
| MED | `cleanup-cli-e2e-test.sh:23,81`, `cleanup-stashes-e2e-test.sh:20`, `build-test-cycle-multi-iter-test.sh:48,99,146,213` | Top-level bare `cd "$REPO"` with no `trap` → process CWD leaks on early-exit/failure (latent for any in-process runner; also leaves CWD wrong on failure). | Wrap repo ops in a subshell `( cd "$REPO" && … )`, or `trap 'cd "$REPO_ROOT"' EXIT`. |

### Informational (no action for parallelism)
- **The 2 tests without `setup_test_env`** — `daemon-workflow-test.sh` (read-only YAML parse of the
  daemon workflow) and `llm-agent-renderer-interop-test.sh` (pure in-memory function calls). Both
  hermetic by construction; safe to parallelize. Add a one-line comment documenting *why* they skip the
  harness rather than forcing `setup_test_env`.
- `build-empty-diff-done-sentinel-test.sh:77` — `/tmp/empty.patch` is a JSON **string value**, never
  opened. No action.
- `test-helpers.sh` `mock_git` returns the string `/tmp/mock-repo`; no current caller writes under it.
- `install-copy-flow-test.sh`, `zbuild-upgrade-subcommand-test.sh` — run `install.sh` but redirect
  `ZBUILD_HOME`/`ZBUILD_INSTALL_DIR` (and edit a sandbox `src` copy) under `TEST_TEMP_DIR`. Hermetic.
- **Process-level exported env with fixed values (review M4)** — `stage-io-ordering-invariant-test.sh:52–54`
  exports `SLOW_MOCK_CLAUDE_SLEEP=1.5` / `SLOW_MOCK_CLAUDE_PAYLOAD` (fixed); `pipeline-test-stage-fresh-shell-test.sh:49–53`
  exports `_TPL_STAGE_*`. These are *values*, not shared *paths* — safe under the per-subprocess runner
  (each file gets its own process env) and would only matter under a hypothetical in-process runner. The
  co-located `SLOW_MOCK_CLAUDE_MARK` correctly resolves under `TEST_TEMP_DIR`. No action for A3d.
- **`GOLDEN_DIR` export (review M5)** — some golden-consuming tests export
  `GOLDEN_DIR="$REPO_ROOT/tests/golden"`. Read-only in all current callers (golden *diff*, not write);
  benign. Flagged only so a future writer to `GOLDEN_DIR` re-opens this audit.
  (The original example test was retired with the compound-quality lattice in #979.)

### Separate correctness bug (not hermeticity)
- `build-test-cycle-multi-iter-test.sh:99,146` — `ZBUILD_CYCLE_ITER=1 \` `cd "$REPO" && _build_stage_run_inner …`
  applies the inline env var to `cd`, **not** to `_build_stage_run_inner` (it's silently dropped). A real
  test bug independent of parallelism — fix as `( cd "$REPO"; ZBUILD_CYCLE_ITER=1 _build_stage_run_inner … )`.
  File as its own small issue (or fold into A3c).

## Recommendations for the fix issues
1. **A3b (#989):** fix the `run-618` pair (priority) + append `$$` to the defensive RUN_IDs.
2. **A3c (#990) — REPURPOSE:** its original class (worktree/port/global-git) is empty; rescope it to the
   **active `$REPO_ROOT` write** (`deferred-tracker-integration-test.sh` — do this first, it's the only
   non-latent hazard) + the temp-path fallbacks (`/tmp/mark` ×9, `/tmp/gh-calls.log`) + the bare-`cd` CWD
   hygiene + the `ZBUILD_CYCLE_ITER` bug. Partition by file so #989/#990 never edit the same test.
3. **A3d (#991):** after the above, flip the integration tier to parallel and prove 10× stable; the 2
   non-`setup_test_env` files need no change.

## A3d (#991) outcome — integration tier flipped to parallel

The integration tier is now in the default `ZBUILD_PARALLEL_SAFE_TIERS` list and runs through
the bounded FIFO pool. Two pool/stability changes accompanied the flip:

- **`wait -n` pool reaping.** The pool previously drained the *oldest* slot (a bash-3.2-era
  choice). The integration tier has a long-pole test (`core-pipeline-runner-test.sh` ≈ 193 s),
  and draining-oldest let it head-of-line-block the whole pool — capping the speedup at ~1.85×.
  The pool now reaps *any* finished slot via `wait -n` (bash 4.3+; this repo floors at bash 5),
  with a drain-oldest fallback. Aggregation still reads results by submission slot, so output
  ordering is unchanged.

- **Serial-pin escape hatch + the 5 pinned tests.** Increasing real concurrency (the point of
  `wait -n`) surfaced 5 tests that **pass serially but fail when the pool saturates the host** —
  they assert tight wall-clock budgets (signal-abort latency / kill-mid-run timing, 4–8 s) that
  are only reliable on an un-saturated machine. These are pinned to the serial bucket
  (`_ZBUILD_SERIAL_PIN` in `scripts/run-tests.sh`; `ZBUILD_SERIAL_TESTS` env override), running
  sequentially after the pool:

  | Test | Reason |
  |------|--------|
  | `core-pipeline-runner-test.sh` | sleep-stub + kill-mid-run timing; ~193 s long-pole |
  | `full-pipeline-sigint-test.sh` | asserts pipeline halts within 6–8 s (already bumped for slow runners) |
  | `sigint-aborts-pipeline-test.sh` | asserts total wall-clock < 4 s |
  | `sigterm-aborts-pipeline-test.sh` | asserts wall-clock ≤ 5 s |
  | `manifest-sync-similarity-test.sh` | MS5 asserts manifest mtime preserved — wall-clock/mtime sensitive under load (surfaced on CI #1047) |
  | `gh-automation-idempotency-log-test.sh` *(unit tier)* | unconditional `sleep 1` in G8 mtime assertion — load-sensitive under a saturated unit pool (#1425) |

  Note: the table above lists 6 of the 7 `_ZBUILD_SERIAL_PIN` entries. The seventh names a
  compound-quality pipeline test that **does not exist** — it is a stale pin matching nothing.
  It is omitted here deliberately: the audit-integrity guard (#988) requires every test file
  this doc names to be real, so writing it down would trip that guard. The exact entry is
  recorded in the ADR-053 §5 table and is the first candidate for removal under §4.

  The list is capped at **7 entries** by policy (ADR-053 §5) and the cap is enforced
  mechanically by `[SPEC-17]` in `tests/unit/run-tests-parallel-test.sh` — an 8th entry
  fails CI until ADR-053 is amended. Per ADR-053 §4 every entry carries a reason and an
  open follow-up issue; a serial pin is a stopgap, not a destination.

  These are **not** hermeticity bugs (each is isolated via `setup_test_env`); they are
  inherently load-sensitive. Follow-up: make their budgets load-tolerant (scale by a load factor
  or use a mock clock) so they can rejoin the parallel pool.

  **The serial-pin bucket runs FIRST, before the parallel pool** — these tests are pinned
  precisely because they're timing-sensitive, so they execute on an *unloaded* machine rather
  than after the pool has saturated all cores. Running them after the pool flaked
  `full-pipeline-sigint` on a slow 2-core CI runner (#1047) **even though it was pinned**;
  running them first fixes that. Pool and serial-bucket coverage traces use distinct `p<n>`/`s<n>`
  filename prefixes so execution order never collides them. The local 8-core 10× proof was clean;
  the extra pin + the reorder were driven by the weaker CI runner — the empirical-not-static
  lesson, again.

**Timing (local, 8-core):** serial 1095 s → parallel (`wait -n` + 5 pins) ≈ 466 s (**~2.35×**).

**10× stability:** `--tier integration` run 10× in parallel — **10/10 clean, 0 flakes**
(`170/170 passed` each, ~440 s/run, local 8-core). The 5 pins above were identified by running
the freshly-`wait -n`-sharpened pool, which surfaced them consistently before they were pinned.

