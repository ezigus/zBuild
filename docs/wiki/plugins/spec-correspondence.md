# spec-correspondence

The spec-correspondence plugin judges whether each acceptance assertion tests what its SPEC sentence actually says — the one link in the acceptance chain that execution cannot reach.

**Spec Correspondence**

- **Kind:** `agent`
- **Role:** `spec_correspondence`
- **Manifest:** `plugins/agent/spec-correspondence/manifest.yaml`

## Manifest

```yaml
id: spec-correspondence
name: Spec Correspondence
kind: agent
# ADR-040 §5: it makes a model call, so it may NOT sit on a convergence path.
# Its finding reaches test-author on the next iteration through the summary
# channel. Promotion to blocking is a separate decision needing a §5 amendment
# and observed accuracy — deliberately not taken here.
convergence: advisory
version: 0.1.0
description: |
  Judges whether each acceptance assertion tests what its SPEC sentence says.

  Levels 2 and 3 of ADR-036 are experiments: they prove an assertion CAN fail and
  that the wiring is load-bearing. Neither can establish correspondence, and a
  passing test proves the implementation satisfies the ASSERTION, never that the
  assertion satisfies the SENTENCE. Two runs shipped an assertion that checked
  the literal opposite of its SPEC and passed every level honestly
  (ADR-036:512; #1978).

  Runs BEFORE build. Its question needs the requirement and the assertion, not
  the implementation — and at that point in the iteration the implementation does
  not exist yet, so the isolation is a fact of placement rather than a rule.

hooks:
  run: spec_correspondence_run

requires:
  core:
    - redaction
    - event-bus
    - router

provides:
  role: spec_correspondence
  result_contract: 2
  events:
    - spec_correspondence.judged
    - spec_correspondence.no_contract
    - spec_correspondence.result.write_failed

config:
  # Four words, and `partial` earns its place by measurement: with three, a
  # judge shown narrow-but-correct coverage must call it `mismatch`, which put
  # false mismatches at 6/15 on merged pairs. With `partial` it is 0/15, and no
  # true positive was lost. `mismatch` is the word that would ever block;
  # `partial` names a coverage gap and informs.
  valid_verdicts:
    - corresponds
    - partial
    - mismatch
    - uncheckable
  tier_default: T2

inputs:
  - id: design
    required: true

outputs:
  - id: spec_correspondence_result
    path: "${artifact_dir}/spec-correspondence-result.json"
    type: spec-correspondence-result.json@1
    format: json
    required: true
    primary: true
  # ADR-055 §9: this stage's statement of what it DID.
  - id: spec_correspondence_summary
    path: "${artifact_dir}/spec-correspondence-summary.md"
    type: spec-correspondence-summary.md@1
    format: markdown
    required: true
    summary: true
```
