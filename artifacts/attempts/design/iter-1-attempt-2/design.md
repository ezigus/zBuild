# Design: Factor gtimeout-first probe into shared helper and add bare-timeout lint (issue #1752)

## Architectural decision summary

**Goal.** Six places in the codebase each copy the same three-to-twelve line probe (`gtimeout`-first binary discovery + optional `-k` probe). This is a DRY violation: each copy can drift (the `route.sh` sites lack `-k` support today), and adding a new probe site means copying again.

**Context.** `_acceptance_timeout_prefix` already exists in `scripts/lib/acceptance-block.sh` (#1660) as the canonical version of this probe, used by the two acceptance-gate libs. The six other sites are unaware of it. `scripts/lib/timeout-cmd.sh` does not yet exist.

**Decision.** Extract `_acceptance_timeout_prefix` from `acceptance-block.sh` into a new, standalone `scripts/lib/timeout-cmd.sh`. Replace each of the six inline probes with a guard-sourced call to the shared helper. Add `scripts/lib/lint-bare-timeout.sh` that fails on any bare `timeout` command invocation in `core/`, `scripts/`, or `plugins/`, wired into `npm run lint` via `package.json`. Amend ADR-036 with an `## Enforced by` entry. `release.sh:629`'s bare `timeout` call is exempted inline with a stated reason.

**Kill-grace alignment.** `run-tests.sh` uses `ZBUILD_TEST_KILL_GRACE` and `run-mutation.sh` uses `ZBUILD_MUTATION_KILL_GRACE`; the shared helper reads `ZBUILD_NEGCTL_KILL_GRACE`. Callers must bridge before calling the helper: `export ZBUILD_NEGCTL_KILL_GRACE="${CALLER_VAR:-10}"`. Using `export` is mandatory — a bare assignment triggers SC2034 because shellcheck cannot see the variable's use inside the sourced function. The `export` signals intent to pass the value to called contexts.

**`summary.sh` guard sentinel.** `plugins/agent/build/lib/summary.sh:23` uses `declare -F _acceptance_timeout_prefix` to guard-source `acceptance-block.sh`. After the move, this sentinel identifies "has timeout-cmd.sh been sourced?" — which may not equal "has acceptance-block.sh been sourced?". In the actual execution path, `build/plugin.sh:47` always sources `acceptance-block.sh` before `summary.sh` is reached, so the guard is dormant; but it should be updated to check a function unique to `acceptance-block.sh` (e.g., `acceptance_list_spec_ids`) to keep its semantics correct.

**Lint detection gap.** The old inline probe pattern (`command -v gtimeout ... || command -v timeout`) uses `timeout` as an argument to `command -v`, not as a command invocation — the bare-`timeout` lint cannot detect a site that retains the old pattern rather than calling the helper. SPEC-8 closes this gap with a structural grep that asserts every converted site contains `_acceptance_timeout_prefix` and no `command -v gtimeout` inline pattern.

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
```

```acceptance
SPEC-1[code]: sourcing `scripts/lib/timeout-cmd.sh` and calling `_acceptance_timeout_prefix` on a PATH containing only `gtimeout` (no `timeout` binary) populates `_ACCEPTANCE_TOUT[0]` with `gtimeout` covers: R-1 R-3
SPEC-2[code]: sourcing `scripts/lib/timeout-cmd.sh` and calling `_acceptance_timeout_prefix` on a PATH with neither `gtimeout` nor `timeout` leaves `_ACCEPTANCE_TOUT` empty and returns 0 covers: R-1 R-3
SPEC-3[code]: a genuinely failing acceptance testfile (zero diff + red testfile) passed to the build plugin's false-completion guard still produces `inert_build` after the helper is shared covers: R-4
SPEC-4[code]: `scripts/lib/lint-bare-timeout.sh` exits 1 when a `.sh` file in the scanned tree invokes bare `timeout` as a command; exits 0 on a clean fixture; a `# lint-bare-timeout:allow` comment on the flagged line suppresses the finding covers: R-2
SPEC-5[no-code]: `scripts/release.sh` has a `# lint-bare-timeout:allow: <reason>` comment on the same line as the bare `timeout` invocation covers: R-2
SPEC-6[no-code]: `docs/adr/ADR-036-acceptance-contract-teeth.md` contains: (a) a dated amendment heading that includes `#1752`; (b) a reference to `_acceptance_timeout_prefix`; (c) a reference to `scripts/lib/timeout-cmd.sh`; (d) a statement that a bare `timeout` call is a lint failure; (e) an `## Enforced by` section naming `scripts/lib/lint-bare-timeout.sh`; and (f) an `## Enforced by` section naming `tests/unit/lint-bare-timeout-test.sh` covers: R-5
SPEC-7[code]: `package.json`'s `lint` script string contains an invocation of `scripts/lib/lint-bare-timeout.sh`; after all six probe sites are converted and `release.sh` is exempted, running `bash scripts/lib/lint-bare-timeout.sh` on the repository tree exits 0 covers: R-2 R-6
SPEC-8[code]: a structural test greps each of the six converted files (`core/router/route.sh`, `scripts/run-tests.sh`, `scripts/run-mutation.sh`, `scripts/lib/gh-automation.sh`, `scripts/lib/acceptance-block.sh`) and asserts (a) at least one occurrence of `_acceptance_timeout_prefix` and (b) zero occurrences of the old `command -v gtimeout` inline-probe pattern in each; this closes the detection gap because the lint cannot flag a retained inline probe covers: R-1 R-2
SPEC-9[code]: for each of the five non-acceptance-gate call sites (`core/router/route.sh` sync path, `core/router/route.sh` loop path, `scripts/run-tests.sh`, `scripts/run-mutation.sh`, `scripts/lib/gh-automation.sh`), the per-site bridging pattern — setting `ZBUILD_NEGCTL_KILL_GRACE` from the site's own env var, calling `_acceptance_timeout_prefix`, and copying `_ACCEPTANCE_TOUT` to the site's named result variable — produces a non-empty array whose first element is `gtimeout` on a PATH containing only `gtimeout`; SPEC-8's structural check confirms each site uses this pattern rather than an inline probe covers: R-1 R-3
SPEC-10[code]: when `ZBUILD_TEST_KILL_GRACE=42` is set and gtimeout supports `-k`, the per-site bridging simulation for `scripts/run-tests.sh` produces `42` at the kill-grace index of `_ACCEPTANCE_TOUT`; when `ZBUILD_MUTATION_KILL_GRACE=7` is set, the simulation for `scripts/run-mutation.sh` produces `7`; this verifies that `export ZBUILD_NEGCTL_KILL_GRACE="${CALLER_VAR:-10}"` correctly forwards the per-caller kill-grace value covers: R-3
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
