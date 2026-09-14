# Plan checkpoint — issue-1839 spec-acceptance v2 migration

## Files read and what they told me

- plugins/agent/spec-acceptance/manifest.yaml: fully v2 — result_contract:2 at line 68, role:acceptance_gate at 67, events declared at 71-86, valid_verdicts [pass,fail] at 92-94, tier_default:T1 at 95, gate_result primary:true at 114, acceptance_detail required:true+summary:true at 120-125, no cleanup hook (only run hook).
- plugins/agent/spec-acceptance/plugin.sh: result_contract:2 at 4 write sites (181, 273, 562, 567). ZBUILD_STAGE_INPUTS resolution at lines 243-248 with fallback to artifact_dir/design.md. acceptance-summary.txt written on precondition_unmet (185), malformed (276), and final path (549). Line 247 is the fallback only (not a hardcoded primary path).
- tests/integration/acceptance-gate-v2-contract-test.sh: 280 lines, covers SPEC-1 through SPEC-10, C1-C14. All structural assertions cover full v2 contract.
- All 5 existing test helpers have ZBUILD_STAGE_INPUTS exports.

## Conclusions

All implementation is complete (steps 1-4 of prior plan). Only remaining work: run npm test with full tree staged to get the green run and confirm the branch reddens at merge-base.

## If stopped now

Emit plan with single step: run npm test and confirm green. All prior steps already done on branch.
