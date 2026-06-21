# zBuild impact-stage scope overrides

Per-repo overlay for the impact (adversarial consequence-finding) stage. The
shipped charter tells you to hunt for files MISSING from the design scope block.
This file states the zBuild-specific FALSE gaps you must NOT raise.

## Rule IMP-1 — a canonical stage absent from a template is NOT a gap

`_ZBUILD_CANONICAL_STAGES` (core/pipeline/template.sh) is the set of VALID stage
ids. Each template (`config/templates/*.yaml`) uses a SUBSET of them in canonical
order. A stage present in the canonical list but absent from a given template is
CORRECT BY DESIGN, not a missing-enumeration gap.

Do NOT return `verdict=incomplete` demanding that:
- `config/templates/standard.yaml` add a stage it does not currently list, or
- `scripts/lib/test-helpers.sh` `_ZBUILD_STANDARD_ROSTER` grow to include a stage
  that `standard.yaml` does not use,

merely because that stage exists in `_ZBUILD_CANONICAL_STAGES` or in another
template (e.g. `simple.yaml`). EPIC #966's A/B strategy puts new objective/review
stages in `simple.yaml` ONLY; `standard.yaml` stays untouched until the explicit
hand-cutover (#978/#979). Demanding the stage be wired into `standard.yaml` is a
FALSE gap that creates an unbounded out-of-scope edit — the build will add it,
test_assessment will (correctly) fail it as out-of-scope, and the cycle
livelocks (see #970 run 20260620113520).

## Rule IMP-2 — reordering only invalidates templates that contain the stage

A change that REORDERS a stage's position in `_ZBUILD_CANONICAL_STAGES`
invalidates position/index assertions ONLY in tests that exercise a template
which actually contains that stage. A template that omits the stage keeps a valid
subsequence and needs no rescope. Name the specific template + assertion before
flagging a reorder gap.
