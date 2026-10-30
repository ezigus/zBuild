# Scope lens notes — issue #1951

## Files read
- tests/unit/event-schema-emitted-coverage-test.sh (full, 342 lines)
- tests/unit/merge-v2-result-test.sh (full, 378 lines)
- plugins/agent/security-lens/tests/security-lens-test.sh (full, 777 lines)
- tests/unit/lint-adr-enforced-by-test.sh (full, 181 lines)
- docs/adr/ADR-001-plugin-contract.md (lines 330-355, Enforced-by section)
- Verified event-schema-manifest-composition-test.sh exists and its SPEC-4/SPEC-5 tags

## Planned scope
tests/unit/event-schema-emitted-coverage-test.sh ✓ changed
config/event-schema.json ✓ changed
plugins/agent/security-lens/manifest.yaml ✓ changed
plugins/tool/merge/manifest.yaml ✓ changed
plugins/agent/security-lens/tests/security-lens-test.sh ✓ changed
tests/unit/merge-v2-result-test.sh ✓ changed
docs/adr/ADR-001-plugin-contract.md ✓ changed
config/adr-enforcement-baseline.txt ✓ changed
tests/golden/parity/event-sequence.golden (no change expected, not changed)
config/shape-change-paths.txt (no change expected, not changed)

NOT in planned scope but changed:
- tests/unit/lint-adr-enforced-by-test.sh (+26 -0) — OUT OF SCOPE per plan

## SPEC delivery check
- SPEC-1 (dynamic namespace guard): Implemented in sections 5 of coverage test (lines 164-200). _PLUGIN_NS_RE replaced with manifest-derived approach. ✓
- SPEC-2 (engine-namespace check on manifests): Implemented in section 6 (lines 202-246). _ENGINE_OWNED_NS_RE hardcodes ADR-001's engine namespaces (not plugin namespaces). ✓
- SPEC-3 (remove persist.*/hydrate.* from event-schema.json): Done in config/event-schema.json diff. Section 7 of coverage test checks this + adds positive check that plugin manifests still have their declarations. ✓ (slight extension)
- SPEC-4 (remove plugin.result from manifests + update tests): Done in both manifests. security-lens-test.sh SPEC-16 now only checks security_lens.failed. merge-v2-result-test.sh SPEC-1 no longer checks plugin.result. Section 8 of coverage test verifies removal. ✓
- SPEC-5 (ADR-001 Enforced-by section + baseline removal): Done in ADR-001. Baseline removal done. lint-adr-enforced-by-test.sh adds [#1951/SPEC-5] block. ✓ BUT: lint-adr-enforced-by-test.sh not in planned scope.
- SPEC-6 (_PLUGIN_NS_RE absent): Verified — no literal _PLUGIN_NS_RE in file. Self-referential check in section 9 (lines 324-338) uses concat trick. ✓

## Key correctness observations
- "all-but-last" namespace extraction for SPEC-1 correctly handles plugin.pr_open.* exception (3 components → namespace plugin.pr_open, not plugin)
- _ENGINE_OWNED_NS_RE list matches ADR-001's stated engine namespaces per design doc
- pr-open exception in SPEC-2 correctly uses `basename` of plugin dir with dash→underscore substitution
- merge/manifest.yaml: entire events: section removed (correct, plugin.result was the only entry)
- Verified event-schema-manifest-composition-test.sh exists; ADR Enforced-by third bullet is valid

## Findings
1. lint-adr-enforced-by-test.sh out of planned scope (low)
2. ADR-001 Enforced-by section adds third bullet beyond what SPEC-5 required (low)  
3. Coverage test SPEC-3 adds positive checks beyond what the issue's SPEC-3 requires (low)

Score: 8/10
