# Build checkpoint — issue #1668 — COMPLETE

All changes made and verified.

## Changes made

1. **simple.yaml**: Removed `- impact` and surrounding comment from delivery_loop.flow; removed the 4-line comment about impact being a semantic sibling from design_verify_cycle banner; removed the entire `impact:` stage section (~29 lines).
2. **deployed.yaml**: Removed `- impact` from delivery_loop.flow; removed the `impact:` stage section (~12 lines).
3. **run-status-comment-mock-roster.sh**: Removed `_make_impact_plugin()` function body; removed `_make_plugin "impact" "impact_analyzer"` call.
4. **cycle-gate-unavailable-aborts-run-test.sh**: Same removals.
5. **cycle-rate-limit-aborts-run-test.sh**: Same removals.
6. **cycle-acceptance-terminal-failure-test.sh**: Same removals.
7. **cycle-on-max-pipeline-continues-test.sh**: Removed `_make_plugin "impact" "impact_analyzer"` call; updated comment removing "impact →" from stage flow description.
8. **ADR-068**: Updated §1 to "design loop → build loop"; updated §8 to remove "impact" from stages that answer findings; added "Amended 2026-10-10" to header; updated Enforced by §1 to add SPEC-18 and deployed-template-e2e-test.sh.

## Test results
- template-simple-yaml-test.sh: 104/104 pass
- core-pipeline-cycle-build-test-wiring-test.sh: 30/30 pass
- deployed-template-e2e-test.sh: 32/32 pass
- lint-adr-enforced-by.sh: 0 failures
