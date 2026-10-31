# Test stage summary

- verdict: fail
- passed: 831
- failed: 5
- exit_code: 1

## Failing files

- plugins/agent/intake/tests/intake-result-test.sh — ✗ [#1754/SPEC-4] _intake_run_inner returns non-zero on intake.md failure — expected: 1, got: 0
- tests/unit/lint-disposition-words-test.sh — ✗ [SPEC-4] the shipped plugins/ tree passes — expected: 0, got: 1
- tests/unit/plugin-primary-output-atomic-test.sh — ✗ [#1754/SPEC-8] all pre-existing | atomic_write calls outside bug-fix files carry || true
- tests/unit/stage-signal-test.sh — ✗ [G5] every literal unavailable names its service — expected: 0, got: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-4] the shipped plugins/ tree passes
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-8] all pre-existing | atomic_write calls outside bug-fix files carry || true
    [2mmissing || true at: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/core/state/resume.sh:80 /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/core/output/stage-io.sh:637 /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/plugins/agent/build/lib/secrets.sh:172 /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/plugins/tool/test/lib/own-checks.sh:72 /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/plugins/tool/test/lib/own-checks.sh:96 /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/plugins/tool/test/lib/own-checks.sh:101[0m
  [38;2;248;113;113m✗[0m [G5] every literal unavailable names its service
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] _intake_run_inner returns non-zero on intake.md failure
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] intake-result.json carries outcome=broken
    [2mexpected: broken, got: pass[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] reason names intake.md
    [2moutput missing: intake.md[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/tests/unit/lint-disposition-words-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/tests/unit/plugin-primary-output-atomic-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/tests/unit/stage-signal-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.NwBX0g/plugins/agent/intake/tests/intake-result-test.sh
lint: FAIL (npm run lint)
  [38;2;0;212;255mSPEC-5: wiring[0m
  [38;2;74;222;128m✓[0m [SPEC-5] npm run lint runs it
  [38;2;74;222;128m✓[0m [SPEC-5] the CI Lint job runs it
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
  [38;2;74;222;128m✓[0m [#1754/SPEC-8] | atomic_write calls still present outside bug-fix files (not removed)
  [38;2;248;113;113m[1m1 of 29 tests failed[0m
  [38;2;74;222;128m✓[0m [G5] every plugin's signal handling uses the helper
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;248;113;113m[1m3 of 43 tests failed[0m
lint-llm-envelope: OK — 57 plugin source(s) checked, no markdown-document envelope fields
lint-disposition-classify: 1 manifest(s) checked, all declared failure classes classify
lint-silenced-redirect: clean
lint-test-errexit: clean
lint-disposition-words: tool/test/plugin.sh:1209 writes outcome 'is', which the engine does not know
lint-disposition-words: 1 problem(s) among 41 literal disposition(s) — an off-set word, or an unexplained 'unavailable'; the set is: complete unusable timed_out out_of_turns interrupted throttled rate_limited unavailable misconfigured broken
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — SPEC-1/SPEC-2: its test already passes on the code from before this change, so it cannot tell whether the change was made — make it check something the old code gets wrong; SPEC-4: its test does not pass on the new code — the code or the test is wrong; the run of timeout:SPEC-5/timeout:SPEC-6/timeout:SPEC-7's test on the code from before this change could not be done (a problem in the pipeline, not in your change); putting timeout:plugins/tool/test/plugin.sh/timeout:package.json/timeout:core/detect/platforms.sh/timeout:core/output/destinations.sh/timeout:core/pipeline/state_helpers.sh/timeout:plugins/agent/pr-delivery/plugin.sh/timeout:plugins/tool/merge/plugin.sh/timeout:plugins/tool/output-github-comment/plugin.sh/timeout:plugins/tool/pr-open/plugin.sh/timeout:plugins/tool/test/lib/acceptance-check.sh/timeout:plugins/tool/test/lib/acceptance-reason.sh/timeout:scripts/lib/lint-atomic-write-unchecked.sh back to its old version could not be done (a problem in the pipeline, not in your change)
