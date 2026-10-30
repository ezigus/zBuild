# Build notes for #1951

## Files read
- tests/unit/event-schema-emitted-coverage-test.sh (test, READ-ONLY)
- tests/unit/lint-adr-enforced-by-test.sh (test, READ-ONLY)
- config/event-schema.json (11 persist.*/hydrate.* entries to remove)
- plugins/agent/security-lens/manifest.yaml (plugin.result in events to remove)
- plugins/tool/merge/manifest.yaml (plugin.result in events to remove)
- docs/adr/ADR-001-plugin-contract.md (need ## Enforced by section added)
- config/adr-enforcement-baseline.txt (need ADR-001-plugin-contract.md removed)
- plugins/tool/pr-open/manifest.yaml (has plugin.pr_open.* events - concern)
- plugins/tool/persist/manifest.yaml (canonical persist.* declarations)
- plugins/tool/hydrate/manifest.yaml (canonical hydrate.* declarations)
- core/event-bus/known-types.sh (eb_manifest_events function)
- scripts/lib/lint-adr-enforced-by.sh (format for ## Enforced by)

## Analysis

### SPEC-3: Remove persist.* and hydrate.* from event-schema.json
Straightforward: remove 11 entries.

### SPEC-4: Remove plugin.result from security-lens and merge manifests
Straightforward: remove the plugin.result line from both.

### SPEC-5: Add ## Enforced by to ADR-001, remove from baseline
Need to add section naming tests/unit/event-schema-emitted-coverage-test.sh.
The lint script (lint-adr-enforced-by.sh) requires backtick-wrapped paths.
The SPEC-5 test checks that "event-schema-emitted-coverage-test.sh" appears
in the section body.

### CONCERN: pr-open and SPEC-1/SPEC-2
The test for SPEC-1 collects ALL namespace prefixes from ALL plugin manifests'
events, including pr-open which declares plugin.pr_open.* events. This adds
'plugin' to the plugin namespace set. Then SPEC-1 checks if any engine event
has a namespace prefix in that set - and plugin.* engine events would be flagged.

Similarly SPEC-2 checks if any plugin manifest event matches _ENGINE_OWNED_NS_RE
(which includes 'plugin'), and pr-open's plugin.pr_open.* events match.

HOWEVER - the design decision says engine-owned namespaces should be filtered out
of the plugin namespace set. Maybe the test author DID implement this filtering
but I'm missing it. Let me just run the test after the changes.

## Changes needed
1. config/event-schema.json: remove hydrate.* (5 entries) and persist.* (6 entries)
2. plugins/agent/security-lens/manifest.yaml: remove plugin.result from events
3. plugins/tool/merge/manifest.yaml: remove plugin.result from events
4. docs/adr/ADR-001-plugin-contract.md: add ## Enforced by section
5. config/adr-enforcement-baseline.txt: remove ADR-001-plugin-contract.md line
echo "Notes updated"

## Test results after changes

### SPEC-3: PASSES
- persist.* removed from event-schema.json
- hydrate.* removed from event-schema.json

### SPEC-4: PASSES
- plugin.result removed from security-lens manifest
- plugin.result removed from merge manifest

### SPEC-5: PASSES
- ADR-001 has ## Enforced by section
- ADR-001-plugin-contract.md removed from baseline

### SPEC-1 and SPEC-2: BLOCKED
The test for SPEC-1 collects ALL namespace prefixes from ALL plugin manifests
without filtering engine-owned ones. pr-open has plugin.pr_open.* events, 
adding 'plugin' to the namespace set, causing all plugin.* engine events to
be flagged.

The test for SPEC-2 uses _ENGINE_OWNED_NS_RE which includes 'plugin'. This
matches pr-open's events. No exception for pr-open in the test code.

Fix requires changing plugins/tool/pr-open/manifest.yaml (OUT OF SCOPE).
