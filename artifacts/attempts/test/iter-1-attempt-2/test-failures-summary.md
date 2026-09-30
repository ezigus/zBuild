# Test stage summary

- verdict: fail
- passed: 778
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/impact-v2-result-contract-test.sh — ✗ [#1838/SPEC-14] provides.events includes impact.contract.violation

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.contract.violation
    [2mimpact.contract.violation not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.envelope.malformed
    [2mimpact.envelope.malformed not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.envelope.recovered
    [2mimpact.envelope.recovered not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.hallucination.filtered
    [2mimpact.hallucination.filtered not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.scope.expanded
    [2mimpact.scope.expanded not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.scope.plateau
    [2mimpact.scope.plateau not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.verdict.complete
    [2mimpact.verdict.complete not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.verdict.error
    [2mimpact.verdict.error not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-14] provides.events includes impact.verdict.incomplete
    [2mimpact.verdict.incomplete not listed in provides.events of /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-17] manifest valid_verdicts includes complete
    [2mcomplete not listed under valid_verdicts in /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-17] manifest valid_verdicts includes incomplete
    [2mincomplete not listed under valid_verdicts in /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [#1838/SPEC-17] manifest valid_verdicts includes error
    [2merror not listed under valid_verdicts in /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/plugins/agent/impact/manifest.yaml[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.prwRXd/tests/unit/impact-v2-result-contract-test.sh
```
