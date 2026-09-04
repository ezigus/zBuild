# Test stage summary

- verdict: fail
- passed: 674
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Kdoxpt/tests/e2e/plugin-event-balance-full-run-test.sh
  [38;2;248;113;113m✗[0m [SPEC-1] plugin.run.start count == plugin.run.complete count
    [2mexpected: 9, got: 8[0m
  [38;2;248;113;113m✗[0m [SPEC-2] plugin.run start/complete balance holds for every individual plugin
  [38;2;248;113;113m✗[0m [SPEC-1] plugin.run.start count == plugin.run.complete count
  [38;2;248;113;113m✗[0m [SPEC-2] plugin.run start/complete balance holds for every individual plugin
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Kdoxpt/tests/e2e/parity-local-vs-ci-test.sh
  [38;2;248;113;113m✗[0m fixture runs exit 0 in local mode
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m local run pipeline status=complete
    [2mexpected: complete, got: interrupted[0m
  [38;2;248;113;113m✗[0m event type sequence identical in local and CI modes
    [2mexpected: memory.backend.init
  [38;2;248;113;113m✗[0m stage_statuses identical in local and CI modes
    [2mexpected: {"build":"failed","hydrate":"complete","intake":"complete","plan":"complete"}, got: {"build":"complete","hydrate":"complete","intake":"complete","plan":"complete","pr":"complete","review-aggregator":"complete","test":"complete"}[0m
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
  [38;2;248;113;113m✗[0m full pipeline-state.json identical after normalization
    [2mexpected: {
  [38;2;248;113;113m✗[0m artifact filename list identical across modes
    [2mexpected: ./artifacts/build-prompt.txt
  [38;2;248;113;113m✗[0m all artifact contents identical across modes (sha256, timestamps normalized)
  [38;2;248;113;113m✗[0m normalized state.json matches golden snapshot
  [38;2;248;113;113m✗[0m artifact filename list matches golden snapshot
  [38;2;248;113;113m✗[0m fixture runs exit 0 in local mode
  [38;2;248;113;113m✗[0m local run pipeline status=complete
  [38;2;248;113;113m✗[0m event type sequence identical in local and CI modes
  [38;2;248;113;113m✗[0m stage_statuses identical in local and CI modes
  [38;2;248;113;113m✗[0m event sequence matches golden snapshot
  [38;2;248;113;113m✗[0m full pipeline-state.json identical after normalization
  [38;2;248;113;113m✗[0m artifact filename list identical across modes
  [38;2;248;113;113m✗[0m all artifact contents identical across modes (sha256, timestamps normalized)
  [38;2;248;113;113m✗[0m normalized state.json matches golden snapshot
  [38;2;248;113;113m✗[0m artifact filename list matches golden snapshot
```
