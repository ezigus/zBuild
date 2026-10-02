# Test stage summary

- verdict: fail
- passed: 785
- failed: 5
- exit_code: 1

## Failing files

- tests/integration/route-back-budget-exhausted-test.sh — ✗ S2: cycle.route_back emitted exactly once (budget=2 → one jump) — expected: 1, got: 0
- tests/unit/event-schema-emitted-coverage-test.sh — ✗ emitted type 'cycle.member_unfinished.suppressed_convergence' is in the composed known set
- tests/unit/lint-disposition-words-test.sh — ✗ [SPEC-4] the shipped plugins/ tree passes — expected: 0, got: 1
- tests/unit/stage-signal-test.sh — ✗ [G5] every literal unavailable names its service — expected: 0, got: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-4] the shipped plugins/ tree passes
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m emitted type 'cycle.member_unfinished.suppressed_convergence' is in the composed known set
    [2mnot in config/event-schema.json nor any manifest's provides.events[0m
  [38;2;248;113;113m✗[0m [G5] every literal unavailable names its service
  [38;2;248;113;113m✗[0m S2: cycle.route_back emitted exactly once (budget=2 → one jump)
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m S2: plan dispatched TWICE then budget spent (no third)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m S2: budget spent → fallback rc=8 → status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m S2: cycle.complete restates the ORIGINAL cause, not route_back
    [2mexpected: member_terminal_failure, got: [0m
  [38;2;248;113;113m✗[0m S2: pipeline.end reason is the ORIGINAL cause, not route_back
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.LlrdzJ/tests/unit/lint-disposition-words-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.LlrdzJ/tests/unit/event-schema-emitted-coverage-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.LlrdzJ/tests/unit/stage-signal-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.LlrdzJ/tests/integration/route-back-budget-exhausted-test.sh
lint: FAIL (npm run lint)
  [38;2;0;212;255mSPEC-5: wiring[0m
  [38;2;74;222;128m✓[0m [SPEC-5] npm run lint runs it
  [38;2;74;222;128m✓[0m [SPEC-5] the CI Lint job runs it
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 13 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-1717-2] config/event-schema.json carries no plugin-owned namespace
  [38;2;74;222;128m✓[0m [SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself
  [38;2;74;222;128m✓[0m [SPEC-5] redaction.marker_neutralized is registered in event-schema.json known_types
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
  [38;2;74;222;128m✓[0m [G5] every plugin's signal handling uses the helper
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;248;113;113m[1m5 of 5 tests failed[0m
lint-disposition-classify: 1 manifest(s) checked, all declared failure classes classify
lint-silenced-redirect: clean
lint-verdict-words: 192 literal verdict(s) checked, all declared by their manifests
lint-disposition-words: agent/spec-correspondence/plugin.sh:315 writes 'unavailable' without naming the external service — add '# disposition-ok: <service> is not responding' (or derive it from router_reason_disposition)
lint-disposition-words: agent/review-report/plugin.sh:180 writes 'unavailable' without naming the external service — add '# disposition-ok: <service> is not responding' (or derive it from router_reason_disposition)
lint-disposition-words: 2 problem(s) among 118 literal disposition(s) — an off-set word, or an unexplained 'unavailable'; the set is: complete unusable timed_out out_of_turns interrupted throttled rate_limited unavailable misconfigured broken
```
