# Build notes for #1951 (iteration 3)

## Final verified state

All required changes are committed and all SPEC tests pass. No further changes needed.

### Changes committed in previous iterations

**Commit 20a236d3**: Data/config changes:
1. config/event-schema.json: persist.* (6) and hydrate.* (5) entries removed
2. plugins/agent/security-lens/manifest.yaml: plugin.result removed
3. plugins/tool/merge/manifest.yaml: (already clean, no events section)
4. docs/adr/ADR-001-plugin-contract.md: ## Enforced by section added
5. config/adr-enforcement-baseline.txt: ADR-001-plugin-contract.md removed

**Commits 95b7c526, 280b8651, 7fd1c7ca** (test-author): Test changes:
- tests/unit/event-schema-emitted-coverage-test.sh: new dynamic SPEC-1/2/3/4/6 assertions,
  _PLUGIN_NS_RE removed entirely
- plugins/agent/security-lens/tests/security-lens-test.sh: SPEC-16 updated to check
  security_lens.failed only (plugin.result sub-assertion removed)
- tests/unit/merge-v2-result-test.sh: SPEC-1 updated to check result_contract/role only
  (plugin.result sub-assertion removed)

### VERIFIED: All SPECs pass on current tree

- tests/unit/event-schema-emitted-coverage-test.sh → All 16 tests passed (SPEC-1/2/3/4/6 ✓)
- plugins/agent/security-lens/tests/security-lens-test.sh → All 93 tests passed ✓
- tests/unit/merge-v2-result-test.sh → All 54 tests passed ✓
- tests/unit/lint-adr-enforced-by-test.sh → All 27 tests passed (SPEC-5 ✓)

### Addressing previous stage findings

**issue-acceptance finding 1** (_PLUGIN_NS_RE not removed): RESOLVED. Grep confirms it
is absent from event-schema-emitted-coverage-test.sh. The test-author commits already
removed the SPEC-1717-2 block and replaced it with the dynamic manifest-derived guard.

**issue-acceptance finding 2** (two pre-existing tests fail): RESOLVED. The test-author
commits (7fd1c7ca) updated security-lens-test.sh and merge-v2-result-test.sh to remove
the plugin.result sub-assertions. Both now check only what they're entitled to assert
(security_lens.failed for SPEC-16; result_contract/role for SPEC-1). Both tests pass.

**test finding 10** (wiring check): event-schema-emitted-coverage-test.sh is a
standalone test script run directly by the test harness. WIRING: none.

**test findings 1-9** (golden file/shape-floor warnings): Heuristic alerts, not actual
failures. The parity golden file is unaffected — persist/hydrate events remain in the
composed known set via plugin manifests; only the redundant engine-config leg was
removed. All shape-floor and template tests pass (verified).

## No further changes required — implementation complete
