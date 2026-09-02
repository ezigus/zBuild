# Test failures summary

## Failing lines (extracted)

```
unit: FAIL plugins/agent/build/tests/build-test.sh
  [38;2;248;113;113m✗[0m [SPEC-8] manifest provides.result_contract == 2
    [2mexpected: 2, got: [0m
  [38;2;248;113;113m✗[0m [SPEC-8] manifest provides.result_contract == 2
unit: FAIL tests/e2e/parity-local-vs-ci-test.sh
  [38;2;248;113;113m✗[0m fixture runs exit 0 in local mode
    [2mexpected: 0, got: 2[0m
  [38;2;248;113;113m✗[0m pipeline-state.json created (local)
  [38;2;248;113;113m✗[0m fixture runs exit 0 in CI mode
    [2mexpected: 0, got: 2[0m
  [38;2;248;113;113m✗[0m local run pipeline status=complete
    [2mexpected: complete, got: [0m
  [38;2;248;113;113m✗[0m CI run pipeline status=complete
    [2mexpected: complete, got: [0m
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
unit: FAIL tests/e2e/plugin-event-balance-full-run-test.sh
  [38;2;248;113;113m✗[0m mocked full run exits 0
    [2mexpected: 0, got: 2[0m
  [38;2;248;113;113m✗[0m [SPEC-1] the run dispatched at least one plugin
  [38;2;248;113;113m✗[0m [SPEC-5] plugins report domain results as plugin.result
  [38;2;248;113;113m✗[0m mocked full run exits 0
  [38;2;248;113;113m✗[0m [SPEC-1] the run dispatched at least one plugin
  [38;2;248;113;113m✗[0m [SPEC-5] plugins report domain results as plugin.result
unit: FAIL tests/integration/full-pipeline-enforce-mode-test.sh
  [38;2;248;113;113m✗[0m default-mode: structured error printed on stderr
  [38;2;248;113;113m✗[0m default-mode: pipeline.preflight.fail event emitted
  [38;2;248;113;113m✗[0m default-mode: structured error printed on stderr
  [38;2;248;113;113m✗[0m default-mode: pipeline.preflight.fail event emitted
unit: FAIL tests/integration/pipeline-preflight-missing-stage-test.sh
  [38;2;248;113;113m✗[0m enforce: structured error printed on stderr
    [2mno 'Pipeline cannot start' in stderr; err-tail: ✗ load_template: stage 'build' resolves to no plugin (ADR-047 §5: every leaf must resolve via role or id; add a plugin whose provides.role matches, or whose id is 'build')
✗ Failed to load template 'broken-contract-missing-producer' — a stage resolves to no plugin (see above); aborting[0m
  [38;2;248;113;113m✗[0m enforce: stderr names the missing producer/input
  [38;2;248;113;113m✗[0m enforce: pipeline.preflight.fail event emitted
  [38;2;248;113;113m✗[0m enforce: state stub written
  [38;2;248;113;113m✗[0m enforce: structured error printed on stderr
  [38;2;248;113;113m✗[0m enforce: stderr names the missing producer/input
  [38;2;248;113;113m✗[0m enforce: pipeline.preflight.fail event emitted
  [38;2;248;113;113m✗[0m enforce: state stub written
unit: FAIL tests/unit/router-manifest-budget-test.sh
  ✗ no shipped manifest is rejected by the new schema check
    expected: , got: plugins/agent/build/manifest.yaml 
  ✗ no shipped manifest is rejected by the new schema check
unit: FAIL tests/unit/stage-checkpoint-test.sh
  [38;2;248;113;113m✗[0m [SPEC-10] plan is the ONLY stage opted in
    [2mexpected: plan , got: build plan [0m
  [38;2;248;113;113m✗[0m [SPEC-10] plan is the ONLY stage opted in
unit: FAIL tests/unit/stage-resolution-parity-test.sh
  [38;2;248;113;113m✗[0m [SPEC-3] build → build (role: builder)
    [2mexpected: build, got: [0m
  [38;2;248;113;113m✗[0m [SPEC-3] build → build (role: builder)
unit: FAIL tests/unit/template-resolvability-preflight-test.sh
  [38;2;248;113;113m✗[0m [SPEC-6] shipped corpus loads and every leaf resolves (preflight accepts, corpus=3)
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [SPEC-6] shipped corpus loads and every leaf resolves (preflight accepts, corpus=3)
```
