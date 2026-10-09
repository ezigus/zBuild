# Design: Factor gtimeout-first probe into shared helper and add bare-timeout lint (issue #1752)

## Architectural decision summary

**Goal.** Six places in the codebase each copy the same three-to-twelve line probe (`gtimeout`-first binary discovery + optional `-k` probe). This is a DRY violation: each copy can drift (the `route.sh` sites lack `-k` support today), and adding a new probe site means copying again.

**Context.** `_acceptance_timeout_prefix` already exists in `scripts/lib/acceptance-block.sh` (#1660) as the canonical version of this probe, used by the two acceptance-gate libs. The six other sites are unaware of it. `scripts/lib/timeout-cmd.sh` does not yet exist.

**Decision.** Extract `_acceptance_timeout_prefix` from `acceptance-block.sh` into a new, standalone `scripts/lib/timeout-cmd.sh`. Replace each of the six inline probes with a guard-sourced call to the shared helper. Add `scripts/lib/lint-bare-timeout.sh` that fails on any bare `timeout` command invocation in `core/`, `scripts/`, or `plugins/`, wired into `npm run lint` via `package.json`. Amend ADR-036 with an `## Enforced by` entry. `release.sh:629`'s bare `timeout` call is exempted inline with a stated reason.

**Kill-grace alignment.** `run-tests.sh` uses `ZBUILD_TEST_KILL_GRACE` and `run-mutation.sh` uses `ZBUILD_MUTATION_KILL_GRACE`; the shared helper reads `ZBUILD_NEGCTL_KILL_GRACE`. Callers MUST bridge before calling the helper using `export ZBUILD_NEGCTL_KILL_GRACE="${CALLER_VAR:-10}"`. The `export` keyword is mandatory — a bare assignment (without `export`) causes SC2034 because shellcheck cannot trace the variable's use inside the sourced helper function. Using `export` signals to shellcheck that the variable is passed to called contexts.

**`summary.sh` guard sentinel.** `plugins/agent/build/lib/summary.sh:23` uses `declare -F _acceptance_timeout_prefix` to guard-source `acceptance-block.sh`. After the move, this sentinel identifies "has timeout-cmd.sh been sourced?" — which may not equal "has acceptance-block.sh been sourced?". In the actual execution path, `build/plugin.sh:47` always sources `acceptance-block.sh` before `summary.sh` is reached, so the guard is dormant; but it should be updated to check a function unique to `acceptance-block.sh` (e.g., `acceptance_list_spec_ids`) to keep its semantics correct.

**Lint detection gap.** The old inline probe pattern (`command -v gtimeout ... || command -v timeout`) uses `timeout` as an argument to `command -v`, not as a command invocation — the bare-`timeout` lint cannot detect a site that retains the old pattern rather than calling the helper. SPEC-8 closes this gap: after all call sites are converted, a conversion-integrity test verifies each site uses the helper and carries no residual inline probe.

**Pre-existing legacy failures.** Two tests (`security-lens-test.sh` and `scope-manifest-b1-regression-test.sh` SPEC-5) fail in issue worktrees because they reference `legacy/` files excluded per ADR-059 §2. These failures pre-date this PR and are not caused by the gtimeout changes. R-6 ("npm test green") is met for all tests introduced or modified by this PR; the legacy-exclusion failures are a separate infrastructure concern.

```scope
scripts/lib/timeout-cmd.sh
scripts/lib/lint-bare-timeout.sh
scripts/lib/acceptance-block.sh
core/router/route.sh
scripts/run-tests.sh
scripts/run-mutation.sh
scripts/lib/gh-automation.sh
scripts/release.sh
package.json
docs/adr/ADR-036-acceptance-contract-teeth.md
config/adr-enforcement-baseline.txt
tests/unit/timeout-cmd-helper-test.sh
tests/unit/lint-bare-timeout-test.sh
tests/unit/acceptance-negctl-test.sh
scripts/lib/acceptance-negctl.sh
scripts/lib/acceptance-reachability.sh
plugins/agent/build/lib/summary.sh
tests/unit/run-mutation-empty-dir-clean-gate-test.sh
tests/unit/run-mutation-stale-anchor-test.sh
```

```acceptance
SPEC-1[code]: sourcing `scripts/lib/timeout-cmd.sh` and calling `_acceptance_timeout_prefix` on a PATH containing only `gtimeout` (no `timeout` binary) populates `_ACCEPTANCE_TOUT[0]` with `gtimeout` covers: R-1 R-3
SPEC-2[code]: sourcing `scripts/lib/timeout-cmd.sh` and calling `_acceptance_timeout_prefix` on a PATH with neither `gtimeout` nor `timeout` leaves `_ACCEPTANCE_TOUT` empty and returns 0 covers: R-1 R-3
SPEC-3[code]: a genuinely failing acceptance testfile (zero diff + red testfile) passed to the build plugin's false-completion guard still produces `inert_build` after the helper is shared covers: R-4
SPEC-4[code]: `scripts/lib/lint-bare-timeout.sh` exits 1 when a `.sh` file in the scanned tree invokes bare `timeout` as a command; exits 0 on a clean fixture; a `# lint-bare-timeout:allow` comment on the flagged line suppresses the finding covers: R-2
SPEC-5[no-code]: `scripts/release.sh` has a `# lint-bare-timeout:allow: <reason>` comment on the same line as the bare `timeout` invocation covers: R-2
SPEC-6[no-code]: `docs/adr/ADR-036-acceptance-contract-teeth.md` satisfies all six of: (a) a heading that contains a date and `#1752` on the same line; (b) the string `_acceptance_timeout_prefix` appears anywhere in the file; (c) the string `scripts/lib/timeout-cmd.sh` appears anywhere in the file; (d) a line matching `bare.*timeout.*lint failure` or `lint failure.*bare.*timeout`; (e) `scripts/lib/lint-bare-timeout.sh` appears after the `## Enforced by` heading and before the next `##` heading; (f) `tests/unit/lint-bare-timeout-test.sh` appears in the same `## Enforced by` section covers: R-5
SPEC-7[code]: `package.json`'s `lint` script string contains an invocation of `scripts/lib/lint-bare-timeout.sh`; after all six probe sites are converted and `release.sh` is exempted, running `bash scripts/lib/lint-bare-timeout.sh` on the repository tree exits 0 covers: R-2 R-6
SPEC-8[code]: a conversion-integrity test run against the repository exits 0 when all five converted non-acceptance-gate call-site files (`core/router/route.sh`, `scripts/run-tests.sh`, `scripts/run-mutation.sh`, `scripts/lib/gh-automation.sh`, `scripts/lib/acceptance-block.sh`) each contain a call to `_acceptance_timeout_prefix` and none retains the old inline probe; when any one of those files is reverted to the pre-conversion inline probe pattern, the test exits 1 — this closes the detection gap where a retained inline probe would not be caught by the bare-timeout lint covers: R-1 R-2
SPEC-9[code]: an inline simulation of each of the five non-acceptance-gate call sites' bridging pattern — constructing `ZBUILD_NEGCTL_KILL_GRACE` from the site's per-caller env var (where the site has one), calling `_acceptance_timeout_prefix` with the site's canonical timeout duration, and capturing `_ACCEPTANCE_TOUT` into the site's named result array — produces a first element of `gtimeout` on a PATH containing only `gtimeout`; this verifies the bridge-and-call idiom each site must implement (the simulation is inline, not sourcing the actual site files; SPEC-8 structurally confirms each site uses the helper) covers: R-1 R-3
SPEC-10[code]: when `ZBUILD_TEST_KILL_GRACE=42` is set and gtimeout supports `-k`, the per-site bridging simulation for `scripts/run-tests.sh` (setting `export ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_TEST_KILL_GRACE:-10}"`) produces `42` at the kill-grace index of `_ACCEPTANCE_TOUT`; when `ZBUILD_MUTATION_KILL_GRACE=7` is set, the simulation for `scripts/run-mutation.sh` produces `7`; this verifies that the mandatory `export ZBUILD_NEGCTL_KILL_GRACE=...` bridge correctly forwards each caller's per-caller grace value to the shared helper covers: R-3
WIRING:
package.json
scripts/lib/acceptance-block.sh
TESTFILES:
SPEC-1: tests/unit/timeout-cmd-helper-test.sh
SPEC-2: tests/unit/timeout-cmd-helper-test.sh
SPEC-3: tests/unit/timeout-cmd-helper-test.sh
SPEC-4: tests/unit/lint-bare-timeout-test.sh
SPEC-5: tests/unit/lint-bare-timeout-test.sh
SPEC-6: tests/unit/lint-bare-timeout-test.sh
SPEC-7: tests/unit/lint-bare-timeout-test.sh
SPEC-8: tests/unit/timeout-cmd-helper-test.sh
SPEC-9: tests/unit/timeout-cmd-helper-test.sh
SPEC-10: tests/unit/timeout-cmd-helper-test.sh
```
