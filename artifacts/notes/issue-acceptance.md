# Issue #1951 Acceptance Notes

## Files read
- tests/unit/event-schema-emitted-coverage-test.sh (full)
- config/event-schema.json (full)
- plugins/agent/security-lens/manifest.yaml (full)
- plugins/tool/merge/manifest.yaml (full)
- docs/adr/ADR-001-plugin-contract.md (full)
- config/adr-enforcement-baseline.txt (full)
- grep checks on security-lens-test.sh and merge-v2-result-test.sh

## Findings per SPEC

**SPEC-1 / R1**: Dynamic derivation confirmed. Lines 148–200 of event-schema-emitted-coverage-test.sh find all manifests at runtime, compute all-but-last-component as namespace, and check each engine schema event against the plugin-namespace set with exact match. No hardcoded list. Would fail if persist.* were re-added to event-schema.json. ✓

**SPEC-2 / R2**: The plugin.pr_open.* exception works correctly. The SPEC-1 check uses all-but-last namespace (`plugin.pr_open.X` → `plugin.pr_open`), so the exact match for `plugin` (engine events) is never triggered by pr-open's events. The SPEC-2 engine-namespace check (lines 202–246) has an explicit exception: `[[ "$_1951_ev2" == "plugin.${_1951_pname2_ns}."* ]] && continue` — for pr-open, `_1951_pname2_ns`=`pr_open`, so `plugin.pr_open.*` events are skipped. ✓

**SPEC-3 / R3 + R4 persist/hydrate**: event-schema.json has no persist.* or hydrate.* events (confirmed by grep returning empty). Test lines 248–285 explicitly check for their absence and would fail if re-added. ✓

**SPEC-4 / R4 plugin.result**: security-lens manifest has only `security_lens.failed` under provides.events — no `plugin.result`. Merge manifest has no `provides.events` key at all. Test lines 287–322 check both manifests. Also checks the removed sub-assertions: "manifest provides.events contains plugin.result" is absent from security-lens-test.sh, and "manifest provides.events includes plugin.result" is absent from merge-v2-result-test.sh. Both confirmed absent by grep. ✓

**SPEC-5**: ADR-001 has `## Enforced by` section at line 344 naming `tests/unit/event-schema-emitted-coverage-test.sh` with [#1951/SPEC-1] and [#1951/SPEC-2]. `ADR-001-plugin-contract.md` is absent from config/adr-enforcement-baseline.txt. lint-adr-enforced-by enforces this. ✓

**SPEC-6 / R5**: No literal `_PLUGIN_NS_RE` in the test file (grep returns empty). The self-check at lines 324–338 assembles the name via string concatenation to avoid a self-referential literal, and checks its own body for the contiguous string. ✓

## Conclusion

All six SPECs met. Tests pass (831/0). Each test would fail if its corresponding config/code change were reverted.
