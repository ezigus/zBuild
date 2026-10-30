# test-author notes — seventh pass (verification)

## Status: COMPLETE — no changes needed

All test assertions were written in prior passes and are verified correct by this pass.

## Per-SPEC final verification

### SPEC-1 [#1951/SPEC-1] — event-schema-emitted-coverage-test.sh lines 148-200
- Derives plugin-owned namespace prefixes dynamically from manifests using `${_1951_pev%.*}` (all-but-last component)
- Collects manifests with `find "$REPO_ROOT/plugins" -maxdepth 3 -name 'manifest.yaml' -type f`
- Checks every event in `_engine_types` (from event-schema.json) — if its namespace appears in the plugin namespace set, it's a violation
- FAILS before SPEC-3 lands; PASSES after persist.*/hydrate.* removed from event-schema.json

### SPEC-2 [#1951/SPEC-2] — event-schema-emitted-coverage-test.sh lines 202-246
- Uses `_ENGINE_OWNED_NS_RE` to check plugin manifests don't declare engine-namespace events
- ADR-001 exception: allows `plugin.<plugin_name_dashes_to_underscores>.*` events
- FAILS before SPEC-4 (plugin.result in security-lens/merge manifests); PASSES after

### SPEC-3 [#1951/SPEC-3] — event-schema-emitted-coverage-test.sh lines 248-285
- Four assertions: persist.* and hydrate.* absent from engine known_types; canonical in plugin manifests
- [no-code]: passes after, need not fail before

### SPEC-4 [#1951/SPEC-4] — event-schema-emitted-coverage-test.sh lines 287-322
- Checks plugin.result absent from security-lens and merge manifests
- Checks "manifest provides.events contains plugin.result" absent from security-lens-test.sh
- Checks "manifest provides.events includes plugin.result" absent from merge-v2-result-test.sh
- VERIFIED: both exact strings are ABSENT from their respective test files ✓

### SPEC-5 [#1951/SPEC-5] — lint-adr-enforced-by-test.sh lines 152-176
- Three checks: ADR-001 has ## Enforced by section; section body names coverage test; ADR-001 not in baseline

### SPEC-6 [#1951/SPEC-6] — event-schema-emitted-coverage-test.sh lines 324-338
- Uses split-concatenation to avoid introducing the literal in the file
- Python3 confirms: 0 occurrences of `_PLUGIN_NS_RE` as contiguous string in the file ✓

## Foreign tags confirmed absent

- security-lens-test.sh [SPEC-16]: "manifest provides.events contains plugin.result" → ABSENT ✓
- merge-v2-result-test.sh [SPEC-1]: "manifest provides.events includes plugin.result" → ABSENT ✓

## Design.md WIRING (fixed in sixth pass)

WIRING: none — because the coverage test file is both the [code] change AND the testfile;
the reachability check's testfile-overlay always restores HEAD before running it, so it
cannot be a load-bearing WIRING target. NEGCTL confirms SPEC-1/SPEC-2 fail on old code.
