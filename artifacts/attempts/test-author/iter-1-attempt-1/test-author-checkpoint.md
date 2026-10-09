## Checkpoint — test-author, issue #1752 — COMPLETE

### Files written
- tests/unit/timeout-cmd-helper-test.sh — DONE (SPECs 1, 2, 3, 8, 9, 10)
- tests/unit/lint-bare-timeout-test.sh — DONE (SPECs 4, 5, 6, 7)

### Key design decisions
- SPEC-8 runs BEFORE `source timeout-cmd.sh` in timeout-cmd-helper-test.sh. The grep checks fail before the change (no `_acceptance_timeout_prefix` in converted files, `command -v gtimeout` still present). Then `source timeout-cmd.sh` fails (file doesn't exist) and script exits. Overall: FAIL before change.
- Fake gtimeout: `exit 0` unconditionally. The `-k` probe `gtimeout -k 1 1 true` exits 0 → `_ACCEPTANCE_TIMEOUT_KILL_OK=yes`. No need to actually exec args since tests only check `_ACCEPTANCE_TOUT` array.
- SPEC-3 sources `plugin.sh` with standard mocks from build-false-completion-guard-test.sh. After `timeout-cmd.sh` is sourced at top, `_acceptance_timeout_prefix` is available when `summary.sh` lazy-loads.
- SPEC-10 uses `export ZBUILD_NEGCTL_KILL_GRACE=...` to suppress SC2034 and correctly bridge to the helper.
- lint-bare-timeout-test.sh uses `set -uo pipefail` (without -e) so linter failures are captured via `|| _rc=$?` without exiting.
- SPEC-6 check #1 (`_acceptance_timeout_prefix`) currently PASSES (ADR-036 line 443 mentions it). Checks #2, #3, #4 fail before change. Since SPEC-6 is no-code ("need not fail before"), this is acceptable. SPEC-4 and SPEC-7 ensure the overall test file fails.

### Verification
- Both files pass `bash -n` and `shellcheck --severity=warning`
- All failing conditions verified: timeout-cmd.sh absent, lint-bare-timeout.sh absent, `command -v gtimeout` still in 5 files, release.sh missing allow comment, package.json missing lint entry, ADR-036 missing timeout-cmd.sh/lint-bare-timeout.sh references
