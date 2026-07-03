# ADR-044 — Repo-declarable test-count contract

**Status:** Accepted (2026-07-03, issue #1208)

## Context

The `test` tool plugin (`plugins/tool/test`) parses a test command's stdout into a
`{verdict, passed, failed}` triple via a fixed **recognizer bank** (`parse.sh`): six
pattern functions for zbuild's own `run-tests.sh` aggregate output, jest/vitest, mocha,
pytest, go test, and cargo. Any runner the bank does not recognize falls through to a
fail-safe `summary_unavailable` (verdict=error, counts=null) — it NEVER fabricates counts.

That bank is a per-ecosystem treadmill. It does not cover, e.g., an iOS/Swift target's
`xcodebuild` / `xcresulttool` output, so a Swift repo's granular pass/fail signal is lost
(`failed=null`), which starves the cycle's `failure_count` fidelity (ADR-021 / #511 Pin 10)
and the progress/by-severity logic. Issue #1208 makes the whole convergence mechanism
repo-agnostic (SPEC-8); the granular count is the one place genericity leaked.

## Decision

Add a **first-priority, repo-declarable count source** to `_test_parse_summary`, consulted
BEFORE the recognizer bank. Two forms (checked in order):

- `ZBUILD_TEST_RESULTS_JSON` — path to a JSON file the test command wrote, of shape
  `{ "passed": N, "failed": M, "total": T, "skipped": S? }`. The test plugin re-exports
  this var INTO the fresh-user-shell test subshell (mirroring `ZBUILD_TEST_TIMING_FILE`)
  so a repo's wrapper can honor it; use an absolute path so it resolves both inside the
  rsync'd staging dir and at parse time.
- `ZBUILD_TEST_COUNT_CMD` — a command whose stdout is that JSON (evaluated at parse time).

Resolution order in `_test_parse_summary`:

1. **declared contract** (`_test_parse_declared_count`): if either var yields valid JSON
   with numeric `passed` + `failed`, use it (`verdict=fail` iff `rc != 0` OR `failed > 0`),
   `recognized=1`.
2. **recognizer bank** (unchanged): the six built-in patterns, the out-of-box default for
   common runners when no contract is declared.
3. **fail-safe**: `summary_unavailable` (verdict=error, counts=null) — never guess.

The contract is engine-level and language-neutral: an iOS/Swift repo wraps
`xcodebuild`/`xcresulttool` to emit the JSON; a Go/Python/JS repo can keep relying on the
bank. Any unrecognized runner with no contract still fails **safe** (closed at the gate,
never a false converge).

## Consequences

- **Wins:** repo-agnostic granular count without growing the recognizer bank; iOS/Swift
  (and any bespoke runner) gets honest `failure_count`; the #1208 by-severity outcome is
  driven by a signal every repo can supply.
- **Costs:** two new env vars in the plugin contract; a repo opting in must ensure the
  declared JSON path/command is well-formed (malformed → falls back to the bank, then
  fail-safe — never fabricated).
- **Non-goals:** this does not change the recognizer bank's behavior for recognized
  runners, nor the `summary_unavailable` fail-safe.

## Verification

`tests/unit/test-declared-count-contract-1208-test.sh` covers: declared JSON file →
honest counts (incl. all-green → pass); declared command → counts; unrecognized runner +
no contract → `summary_unavailable`; recognized runner still parses via the bank when no
contract is set.

## References

- ADR-021 Amendment #1208 (cycle semantics: by-severity uses the generic test verdict +
  `failure_count`)
- ADR-042 (stage portability)
- Issue #1208 (timeouts never fatal; single fatal = exhaustion-without-convergence)
