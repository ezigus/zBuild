# Test stage summary

- verdict: fail
- passed: 845
- failed: 6
- exit_code: 1

## Failing files

- tests/integration/from-stage-rehydrate-test.sh — ✗ [#1805/SPEC-3] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR via --from-stage — file not found: /home/runner/work/_temp/zbuild-state/scratch/test/from-stage-rehydrate-1805.X2OBSD/s3-state/artifacts/intake-result.json
- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/SPEC-1] intake emits no stage.start (complete stage skipped) — expected: 0, got: 1
- tests/integration/write-boundary-revert-test.sh — ✗ [D7] the first offence was retried
- tests/unit/lint-grep-c-test.sh — ✗ [SPEC-5] real scripts/ core/ plugins/ tree is clean — expected: 0, got: 1
- tests/unit/stage-retry-test.sh — ✗ [R1] timed_out with progress, no retry: in the template → 2 runs — expected: 2, got: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] real scripts/ core/ plugins/ tree is clean
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [R1] timed_out with progress, no retry: in the template → 2 runs
    [2mexpected: 2, got: 1[0m
  [38;2;248;113;113m✗[0m [R1] the retry that passes is what the dispatch reports
  [38;2;248;113;113m✗[0m [R2] retry: 2 → 3 runs
    [2mexpected: 3, got: 1[0m
  [38;2;248;113;113m✗[0m [R2] every word that means 'did not finish' is retried
  [38;2;248;113;113m✗[0m [R4] a try that changed nothing is not run again
  [38;2;248;113;113m✗[0m [R5] retry: 9 is capped at 5 → 6 runs
    [2mexpected: 6, got: 1[0m
  [38;2;248;113;113m✗[0m [R5] retry: lots → the default 1 → 2 runs
  [38;2;248;113;113m✗[0m [R6] ZBUILD_DISPOSITION_REDISPATCH=4 changes nothing → 2 runs
  [38;2;248;113;113m✗[0m [R7] one stage.retry for the one retry
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [R7] it names the stage
    [2mexpected: twice, got: [0m
  [38;2;248;113;113m✗[0m [R7] ...the outcome the try ended on
    [2mexpected: timed_out, got: [0m
  [38;2;248;113;113m✗[0m [R7] ...which try comes next
    [2mexpected: 2, got: [0m
  [38;2;248;113;113m✗[0m [R7] ...of how many
    [2mexpected: 3, got: [0m
  [38;2;248;113;113m✗[0m [R8] a stage run from a work unit is run again too → 2 runs
  [38;2;248;113;113m✗[0m [R11] each try is told its number
    [2mexpected: 1 2 3 , got: none [0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.oGgEnF/tests/unit/lint-grep-c-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.oGgEnF/tests/unit/stage-retry-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.oGgEnF/tests/integration/from-stage-rehydrate-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.oGgEnF/tests/integration/resume-rehydrate-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.oGgEnF/tests/integration/write-boundary-revert-test.sh
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [SPEC-4] package.json lint script includes lint-grep-c.sh
  [38;2;74;222;128m✓[0m [SPEC-5] .github/workflows/test.yml references lint-grep-c step
  [38;2;74;222;128m✓[0m [SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 21 tests failed[0m
  [38;2;74;222;128m✓[0m cyclic fixture pipeline ran in from-stage-rehydrate test (intake dispatched)
  [38;2;248;113;113m[1m3 of 10 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/SPEC-3] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR via --from-stage
  [38;2;248;113;113m✗[0m [#1805/SPEC-3] restored artifact contains original payload (proves _artifact_persist_restore + _artifact_persist_put_back used git state branch)
  [38;2;248;113;113m✗[0m [#1805/SPEC-3] cyc (cycle) dispatched as the first stage (--from-stage target, intake skipped)
  [38;2;248;113;113m[1m4 of 35 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] intake emits no stage.start (complete stage skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] path 2 (auto-resume): intake emits no stage.start (skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] path 3 (zbuild pipeline resume): intake emits no stage.start (skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-2] no stage.start emitted before exit 1
    [2mexpected: broken, got: unusable[0m
  [38;2;74;222;128m✓[0m [D7] the files are put back
  [38;2;248;113;113m[1m2 of 20 tests failed[0m
  [38;2;248;113;113m✗[0m [D7] the first offence was retried
  [38;2;248;113;113m✗[0m [D7] the retry's offence halts
validate-mechanics-yaml: OK — 18 mechanics validated
lint-doc-freshness: OK — 43 plugin(s), 18 mechanic(s) — all checks passed.
lint-action-versions: OK — no action version drift detected.
lint-grep-c: tests/integration/resume-entry-points-test.sh:294 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _s13_ep_intake_starts="$(jq -r 'select(.type=="stage.start") | .data.stage // empty'      "$_S13_EP_EVENTS_JSONL" 2>/dev/null | grep -c '^intake$' || echo 0)"
lint-grep-c: 1 occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-4: its test already passes on the code from before this change, so it cannot tell whether the change was made — make it check something the old code gets wrong; SPEC-1/SPEC-2/SPEC-3: its test does not pass on the new code — the code or the test is wrong
