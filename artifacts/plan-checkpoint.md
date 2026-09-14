# Plan checkpoint — issue #1848 gate v2 migration

## Files read and key findings

- All 7 gate manifests (coverage-gate, design-gate, gate-aggregator, lint-gate, mutation-gate, secret-scan, shape-floor): already fully v2-compliant — result_contract: 2, valid_verdicts, primary: true, provides.role, provides.events, summary output required: true + summary: true.
- All 7 plugin.sh files: already write result_contract:2, disposition:complete, reason on every exit path; write summary file via stage_summary_write on every terminal verdict including early bail-outs.
- tests/unit/gate-v2-contract-test.sh: covers SPEC-1..13. Missing SPEC-14 (ADR-055 §9 "Suggested acceptance addition" — assert all 7 manifests declare summary required: true, AND assert summary files are actually written on pass and skip verdict paths for all 7 gates).
- shape-floor handles disposition:broken (library_load_failure) and still writes summary.
- secret-scan writes summary with empty reason on pass (stage_summary_write fills "no findings" — acceptable but just barely satisfies §9 "what the stage DID").

## Conclusions

- Five commits on this branch already completed the migration (manifests, plugin.sh, SPEC-1..13 tests).
- The one remaining gap is SPEC-14: the ADR-055 §9 suggested acceptance check — verify all 7 manifests' summary outputs are required: true, AND that each gate writes the summary file on a pass verdict and on a no-input (skip) verdict.
- secret-scan pass summary uses empty reason → stage_summary_write writes "no findings" — marginal but acceptable. Could improve to "clean diff — no secrets found" to fully state what the stage DID.

## What to do next

1. Add SPEC-14 to tests/unit/gate-v2-contract-test.sh: assert all 7 manifests have required: true on their summary output; assert summary files are present after pass/skip runs for each gate.
2. (Optional) Improve secret-scan pass summary reason string.
3. Run npm test.
