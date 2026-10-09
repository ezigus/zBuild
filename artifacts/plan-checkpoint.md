# Plan Checkpoint — Issue #1752

## Files read and key findings

- `scripts/lib/acceptance-block.sh:359-381` — `_acceptance_timeout_prefix(args: timeout_s)` sets `_ACCEPTANCE_TOUT` array. Probes gtimeout→timeout→return 0 (empty). Caches `-k` support in `_ACCEPTANCE_TIMEOUT_KILL_OK` once-per-process. This is the most complete probe and is the candidate to become the shared helper.
- `core/router/route.sh:1046,1943` — inline `_tout_cmd=("gtimeout"|"timeout")`. No `-k` probe. Simple 3-line pattern.
- `scripts/run-tests.sh:34` — `_rt_tout_bin` probe + `-k` probe → builds `_rt_tout` array. Very similar to `_acceptance_timeout_prefix` but uses different variable names.
- `scripts/run-mutation.sh:124` — `_mut_tout_bin` probe + `-k` probe → builds `_mut_tout` array. Same shape as run-tests.sh.
- `scripts/lib/gh-automation.sh:191` — `timeout_cmd` string probe only (no `-k`). 5-line pattern.
- `scripts/release.sh:629` — bare `timeout "$checks_timeout" "$gh_pr_cmd" pr checks …`. Release tooling, out of scope to fix behavior; must be explicitly exempted in lint.
- `plugins/agent/build/lib/summary.sh:23,433` — sources `acceptance-block.sh` and calls `_acceptance_timeout_prefix`. It's a caller, not a probe site.
- `scripts/lib/lint-grep-c.sh` — good template for lint script structure: per-line opt-out comment (`# lint-grep-c:allow`), scans roots, skips legacy/, exempts self.
- `scripts/lib/lint-model-names.sh` — another good lint template.
- `package.json` lint script — long `&&`-chained list. Add `&& bash scripts/lib/lint-bare-timeout.sh` at end.
- `docs/adr/ADR-036-acceptance-contract-teeth.md` — needs new amendment paragraph and `## Enforced by` section.

## Conclusions

Architecture: move `_acceptance_timeout_prefix` to `scripts/lib/timeout-cmd.sh`. Have `acceptance-block.sh` source it. All 5 other sites source `timeout-cmd.sh` and call `_acceptance_timeout_prefix`, then copy `_ACCEPTANCE_TOUT` into their local array variable. This gives them `-k` support too (safe improvement; rc semantics unchanged).

Lint: `scripts/lib/lint-bare-timeout.sh` scans core/, scripts/, plugins/ for bare `timeout ` (word-boundary, not `gtimeout`). Per-line opt-out via `# lint-bare-timeout:allow`. Exempts test-helpers.sh with reason. `scripts/release.sh:629` gets an inline exemption comment.

## Steps planned

1. TDD: `tests/unit/lint-bare-timeout-test.sh`
2. TDD: `tests/unit/timeout-cmd-helper-test.sh`
3. Create `scripts/lib/timeout-cmd.sh`
4. Update `scripts/lib/acceptance-block.sh` (remove fn definition, source timeout-cmd.sh)
5. Update `core/router/route.sh` (both sites)
6. Update `scripts/run-tests.sh`
7. Update `scripts/run-mutation.sh`
8. Update `scripts/lib/gh-automation.sh`
9. Create `scripts/lib/lint-bare-timeout.sh` + exemption in `scripts/release.sh`
10. Update `package.json`
11. Amend `docs/adr/ADR-036-acceptance-contract-teeth.md`
