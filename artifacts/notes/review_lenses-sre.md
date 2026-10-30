# SRE lens notes — issue #1951

## Files read
- tests/unit/event-schema-emitted-coverage-test.sh (full)
- config/event-schema.json (full)
- plugins/agent/security-lens/manifest.yaml (full)
- plugins/tool/merge/manifest.yaml (full)
- plugins/agent/security-lens/tests/security-lens-test.sh (full)
- tests/unit/merge-v2-result-test.sh (full)
- tests/unit/lint-adr-enforced-by-test.sh (full)
- core/event-bus/known-types.sh (full)
- docs/adr/ADR-001-plugin-contract.md (lines 330–355)
- config/adr-enforcement-baseline.txt (full)
- plugins/tool/persist/manifest.yaml (header + events block)
- plugins/tool/hydrate/manifest.yaml (events block)

## Runtime blast radius — ZERO

The 11 persist.*/hydrate.* events removed from event-schema.json remain
in the composed runtime known set via the manifest leg of eb_compose_known_types.
At runtime, eb_known_types_has still returns 0 (known) for those events —
the leg changed, the answer did not. schema-as-warn only; nothing is blocked
by this removal. Same for plugin.result: it remains in event-schema.json and
the engine continues to emit it correctly. Removing it from the two plugin
manifests only corrects incorrect declarations; the event is still known.

## Rollback path — clean

All changes are to config/tests/docs. No data migration, no state files altered,
no runtime schema read by external consumers. Reverting the PR restores the
pre-change state with no additional cleanup.

## SRE-specific findings

### _ENGINE_OWNED_NS_RE (line 217 of event-schema-emitted-coverage-test.sh)

The SPEC-2 check introduces a new hardcoded enumeration of engine-owned
namespace prefixes:
  ^(pipeline|stage|stage_io|plugin|cycle|router|loop|state|registry|
    parallel|redaction|template|strategy|artifact|model|cost|orch|memory|
    backend|detection|llm|selfhost)\.

This list currently matches the actual top-level namespace prefixes in
event-schema.json exactly (verified by deriving them from the file: same 22
namespaces). However, it is not derived from event-schema.json — it is manually
maintained. If a future PR adds a new engine namespace to event-schema.json
without updating this constant, the SPEC-2 guard would not catch a plugin
claiming events in that new namespace.

Severity: low. The list is correct today and engine namespaces are
architecturally stable (adding one is a significant ADR-level change, not a
routine addition). No current gap — the risk is future-facing only.
Introduced by this change.

### Missing cross-check between _ENGINE_OWNED_NS_RE and event-schema.json

There is no assertion that derives the engine namespaces from event-schema.json
and verifies they match _ENGINE_OWNED_NS_RE. The gap could be closed with a
SPEC that extracts prefixes from event-schema.json and checks them against the
constant; that SPEC was not part of this issue's scope. Low severity.

## Confirmed-clean items

- persist.*/hydrate.* still present in composed set (persist plugin: 6 events,
  hydrate plugin: 6 events including adopt.failed which was NEVER in engine-schema)
- plugin.result kept in event-schema.json (engine-owned, correct)
- SPEC-6 self-referential check correctly splits the variable name to avoid
  a false positive; grep won't find the contiguous string in the source
- SPEC-4 absence checks look for exact string literals that no longer appear
  in the test files after their removal
- Rollback is a clean revert; no SLO impact
- Golden file (event-sequence.golden) unaffected: the events remain in the
  composed known set via manifests, so the parity check still passes

## Score: 8/10

One low-severity finding: _ENGINE_OWNED_NS_RE is a new hardcoded enumeration
introduced by this change. All other checks are clean.
