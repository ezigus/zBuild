## Checkpoint — issue #2032 test author — Iteration 2 (fixing spec-correspondence partials + lint)

### Files written / modified

1. tests/integration/cycle-member-unfinished-no-convergence-test.sh — DONE
   - Fixed lint-test-errexit: replaced `set +e / set -e` multi-line in _run_cycle with `RUN_RC=0; cmd || RUN_RC=$?`
   - Added SPEC-1 tests for `out_of_turns` and `interrupted` dispositions (previously only `timed_out`)

2. tests/unit/adr-063-vocabulary-test.sh — DONE (enhanced)
   - SPEC-7: added assertions for replacement vocabulary `timed_out` and `out_of_turns` present
   - SPEC-8: added `assert_gt` for distinct per-stage helper count > 1 (not just count > 0)
   - SPEC-9: added assertion that #2187 appears in amendment context (grep for `mend.*#2187|#2187.*mend`)
   - Removed unused `_adr_text` variable (would cause shellcheck SC2034 warning)

3. tests/unit/spec-coverage-test.sh — DONE (enhanced)
   - SPEC-3: added second test with rc=1 (assert disposition=unavailable), proving any non-zero rc classified

4. tests/unit/spec-correspondence-test.sh — DONE (enhanced)
   - SPEC-4: added test with rc=124 (assert disposition=timed_out), proving timeout rc also classified

5. tests/unit/review-report-v2-contract-test.sh — DONE (enhanced)
   - Added `_RR_FAIL_ALL_RC` variable to stub (makes all lenses fail with given rc)
   - SPEC-5: added multi-lens test (_RR_FAIL_ALL_RC=1), asserting disposition=unavailable for multiple failing lenses

### Key facts

- lint-test-errexit fires only when `set -e` (or `set -o errexit`) appears as a STANDALONE line
  (starting with optional whitespace then `set -`). The single-line form `set +e; cmd; set -e`
  does NOT fire because the line starts with `set +e;`.
- The `| head` sigpipe guard excludes `-test.sh` files, so `| head -1` in integration tests is fine.
- _RR_FAIL_ALL_RC is exported so it reaches subshells in the lenses fan-out.

### All 9 SPECs now addressed
