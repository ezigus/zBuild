# test-author

The test-author plugin writes the acceptance assertions from the design contract, before build implements against them — so the code and the assertion are two independent readings of the SPEC rather than two artifacts of one.

**Test Author**

- **Kind:** `agent`
- **Role:** `test_author`
- **Manifest:** `plugins/agent/test-author/manifest.yaml`

## Manifest

```yaml
id: test-author
name: Test Author
kind: agent
# ADR-040 §5: advisory — it makes a model call, so it may not sit on the
# convergence path. Its work is verified mechanically downstream (the test
# stage runs the assertions; assertion-integrity guards them).
convergence: advisory
version: 0.1.0
description: |
  Authors the acceptance assertions from the design's SPEC sentences, in the
  target's own language, BEFORE build implements against them.

  Build used to own the assertion bodies (#1477, as a side effect of removing a
  bash stub-writer). That made the code and the assertion two artifacts of ONE
  reading of the SPEC: they agree by construction, so nothing comparing them can
  catch a misreading. Two runs shipped exactly that (ADR-036:512; #1978).

  Its ISOLATION is the mechanism, not a courtesy: this stage never sees the
  diff or the build summary. An author that can read the implementation would
  describe it, which is the original defect wearing a different hat.

  Never a mechanical stub-writer — #1477 removed one because a bash stub is
  nonsense in a pytest or Rust repo. Assertions are authored in the target's
  own language by a model.

hooks:
  run: test_author_run

requires:
  core:
    - redaction
    - event-bus
    - router

provides:
  role: test_author
  result_contract: 2
  events:
    - test_author.authored
    - test_author.no_contract
    - test_author.result.write_failed

config:
  # The v2 exemplars' vocabulary (hydrate/persist/teardown). `authored` and
  # `unchanged` would both mean "did its job" and neither classifies, which is
  # ADR-019's table asking whether a new word earns its place. It does not:
  # the reason field already says which happened.
  valid_verdicts:
    - complete
    - degraded
  tier_default: T2

inputs:
  - id: design
    required: true

outputs:
  - id: test_author_result
    path: "${artifact_dir}/test-author-result.json"
    type: test-author-result.json@1
    format: json
    required: true
    primary: true
  # ADR-055 §9: this stage's statement of what it DID.
  - id: test_author_summary
    path: "${artifact_dir}/test-author-summary.md"
    type: test-author-summary.md@1
    format: markdown
    required: true
    summary: true
```
