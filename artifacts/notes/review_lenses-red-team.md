# Red-team review notes — issue #1951

## Files to read
- tests/unit/event-schema-emitted-coverage-test.sh (main change, +193/-13)
- tests/unit/merge-v2-result-test.sh (+5/-8)
- plugins/agent/security-lens/tests/security-lens-test.sh (+3/-6)
- tests/unit/lint-adr-enforced-by-test.sh (+26/-0)
- config/event-schema.json (after removals)
- plugins/agent/security-lens/manifest.yaml (after removal)
- plugins/tool/merge/manifest.yaml (after removal)
- docs/adr/ADR-001-plugin-contract.md (Enforced by section added)

## Status: reading files

## Analysis complete

### Finding 1: _ENGINE_OWNED_NS_RE is a hardcoded enumeration (same class as original bug)
- Line 217 of event-schema-emitted-coverage-test.sh
- Introduced: YES
- Severity: medium
- The change removes _PLUGIN_NS_RE (a hardcoded list of plugin namespaces) and replaces SPEC-2 with a hardcoded list of engine-owned namespaces (_ENGINE_OWNED_NS_RE). This is the same class of antipattern, just in the opposite direction. If a new engine namespace is added to ADR-001 and event-schema.json but _ENGINE_OWNED_NS_RE is not updated, SPEC-2 silently misses plugins claiming it.
- Note: the list currently matches ADR-001 exactly.

### Finding 2: SPEC-2 exception allows ANY plugin to claim plugin.<name>.* events
- Line 232 of event-schema-emitted-coverage-test.sh
- Introduced: YES
- Severity: medium
- R2 specifies "plugin.pr_open.* is the one allowed exception (ADR-001), and only for plugins/tool/pr-open." The implementation exempts `plugin.<dirname>.*` events for ANY plugin directory. A plugin at plugins/tool/my-new-plugin could declare plugin.my_new_plugin.foo without triggering SPEC-2, bypassing the engine-namespace guard. This is a deviation from R2 (the design document generalizes the exception, but R2 is the spec the design was supposed to honor).

### Finding 3: SPEC-1 namespace set not filtered for engine-owned prefixes
- Lines 174-191 of event-schema-emitted-coverage-test.sh
- Introduced: YES
- Severity: low
- The design document says to "remove every prefix that ADR-001 names as engine-owned" from the plugin namespace set before using it in SPEC-1. The implementation does NOT do this filtering. In practice it is benign today because no manifest legitimately declares engine-namespace events after SPEC-4. But if SPEC-2 has a gap (finding 2), an engine-namespace event in a manifest would inject that namespace into the SPEC-1 set, causing false-positive SPEC-1 violations.

### Finding 4: No automated cross-check between _ENGINE_OWNED_NS_RE and ADR-001
- Line 217 of event-schema-emitted-coverage-test.sh
- Introduced: YES
- Severity: low
- The Enforced by section added to ADR-001 names the test file as enforcing the engine-namespace ownership rule. But there is no test that verifies _ENGINE_OWNED_NS_RE in the test file actually matches the namespace list in ADR-001 §"Declared events". The list and the ADR prose can silently diverge.

### Finding 5: eb_manifest_events silently ignores multi-line YAML flow sequences
- core/event-bus/known-types.sh lines 40-55
- Introduced: NO (pre-existing)
- Severity: low
- The parser supports only single-line inline (`events: [a, b]`) or block-list form. Multi-line flow (`events: [\n  a,\n  b\n]`) silently returns empty. SPEC-1 and SPEC-2 both rely on this function; a manifest using the unsupported form would have its events silently omitted, making the guards miss any violations. Not introduced by this change but now load-bearing for the new guards.

## Score: 5/10
