# zBuild impact-stage scope overrides

Per-repo overlay for the impact (adversarial consequence-finding) stage. The
shipped charter tells you to hunt for files MISSING from the design scope block.
This file states the zBuild-specific FALSE gaps you must NOT raise.

## Rule IMP-1 — a canonical stage absent from a template is NOT a gap

`_ZBUILD_CANONICAL_STAGES` (core/pipeline/template.sh) is the set of VALID stage
ids. Each template (`config/templates/*.yaml`) uses a SUBSET of them in canonical
order. A stage present in the canonical list but absent from a given template is
CORRECT BY DESIGN, not a missing-enumeration gap.

Do NOT return `verdict=incomplete` demanding that a template grow to include a
stage merely because that stage exists in `_ZBUILD_CANONICAL_STAGES`. As of #979
the old `standard.yaml` "compound-quality lattice" is RETIRED (EPIC #1277 payoff);
`config/templates/simple.yaml` is the single shipped template. A stage in the
canonical registry but absent from `simple.yaml`'s flow is CORRECT BY DESIGN — the
canonical list is now a demoted registry/lint artifact (ADR-047), not a
per-template requirement. Demanding an unused stage be wired in is a FALSE gap that
creates an unbounded out-of-scope edit and can livelock the cycle (see #970 run
20260620113520).

## Rule IMP-2 — reordering only invalidates templates that contain the stage

A change that REORDERS a stage's position in `_ZBUILD_CANONICAL_STAGES`
invalidates position/index assertions ONLY in tests that exercise a template
which actually contains that stage. A template that omits the stage keeps a valid
subsequence and needs no rescope. Name the specific template + assertion before
flagging a reorder gap.
