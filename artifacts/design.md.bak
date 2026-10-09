# Design: Factor gtimeout-first probe into shared helper and add bare-timeout lint (issue #1752)

## Architectural decision summary

**Goal.** Six places in the codebase each copy the same three-to-twelve line probe (`gtimeout`-first binary discovery + optional `-k` probe). This is a DRY violation: each copy can drift (the `route.sh` sites lack `-k` support today), and adding a new probe site means copying again.

**Context.** `_acceptance_timeout_prefix` already exists in `scripts/lib/acceptance-block.sh` (#1660) as the canonical version of this probe, used by the two acceptance-gate libs. The six other sites are unaware of it. `scripts/lib/timeout-cmd.sh` does not yet exist.

**Decision.** Extract `_acceptance_timeout_prefix` from `acceptance-block.sh` into a new, standalone `scripts/lib/timeout-cmd.sh`. Replace each of the six inline probes with a guard-sourced call to the shared helper. Add `scripts/lib/lint-bare-timeout.sh` that fails on any bare `timeout` command invocation in `core/`, `scripts/`, or `plugins/`, wired into `npm run lint` via `package.json`. Amend ADR-036 with an `## Enforced by` entry. `release.sh:629`'s bare `timeout` call is exempted inline with a stated reason.

**Kill-grace alignment.** `run-tests.sh` uses `ZBUILD_TEST_KILL_GRACE` and `run-mutation.sh` uses `ZBUILD_MUTATION_KILL_GRACE`; the shared helper reads `ZBUILD_NEGCTL_KILL_GRACE`. Callers must pass the correct env var before calling the helper (e.g., `ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_TEST_KILL_GRACE:-10}" _acceptance_timeout_prefix ...`) so the per-caller config is not silently dropped.

**`summary.sh` guard sentinel.** `plugins/agent/build/lib/summary.sh:23` uses `declare -F _acceptance_timeout_prefix` to guard-source `acceptance-block.sh`. After the move, this sentinel identifies "has timeout-cmd.sh been sourced?" — which may not equal "has acceptance-block.sh been sourced?". In the actual execution path, `build/plugin.sh:47` always sources `acceptance-block.sh` before `summary.sh` is reached, so the guard is dormant; but it should be updated to check a function unique to `acceptance-block.sh` (e.g., `acceptance_list_spec_ids`) to keep its semantics correct.

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
SPEC-1[code]: sourcing `scripts/lib/timeout-cmd.sh` and calling `_acceptance_timeout_prefix` on a PATH containing only `gtimeout` (no `timeout` binary) populates `_ACCEPTANCE_TOUT` with `gtimeout` as the binary covers: R-1 R-3
SPEC-2[code]: sourcing `scripts/lib/timeout-cmd.sh` and calling `_acceptance_timeout_prefix` on a PATH with neither `gtimeout` nor `timeout` leaves `_ACCEPTANCE_TOUT` empty and returns 0 covers: R-1 R-3
SPEC-3[code]: a genuinely failing acceptance testfile (zero diff + red testfile) passed to the build plugin's false-completion guard still produces `inert_build` after the helper is shared covers: R-4
SPEC-4[code]: `scripts/lib/lint-bare-timeout.sh` exits 1 when a `.sh` file in the scanned tree invokes bare `timeout` as a command; exits 0 on a clean fixture; a `# lint-bare-timeout:allow` comment on the flagged line suppresses the finding covers: R-2
SPEC-5[no-code]: `scripts/release.sh` line ~629 has a `# lint-bare-timeout:allow: <reason>` comment on the bare `timeout` invocation line covers: R-2
SPEC-6[no-code]: `docs/adr/ADR-036-acceptance-contract-teeth.md` contains a dated amendment paragraph stating that every timeout bound in `core/`, `scripts/`, and `plugins/` resolves through `_acceptance_timeout_prefix` (`scripts/lib/timeout-cmd.sh`) and that a bare `timeout` call is a lint failure; the file also contains an `## Enforced by` section naming `scripts/lib/lint-bare-timeout.sh` and `tests/unit/lint-bare-timeout-test.sh` covers: R-5
SPEC-7[code]: `package.json`'s `lint` script string contains an invocation of `scripts/lib/lint-bare-timeout.sh`; after all six probe sites are converted and `release.sh:629` is exempted, running `bash scripts/lib/lint-bare-timeout.sh` on the repository tree exits 0 covers: R-2 R-6
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
```
