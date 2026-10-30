# Design — #1951: Fix enumerated guard in event-schema coverage test

## Architectural decision summary

**Goal.** The guard in `tests/unit/event-schema-emitted-coverage-test.sh` (SPEC-1717-2) that prevents plugin-owned namespaces from leaking into `config/event-schema.json` is itself a hardcoded enumerated list (`_PLUGIN_NS_RE`). It missed `persist` and `hydrate`, so those plugins' events were double-declared in the engine config for the life of the project, and the guard never caught it. Two other plugins (`security-lens`, `merge`) incorrectly declared the engine event `plugin.result` in their manifests, and the guard had no path to catch that direction either.

**Context.** ADR-001 §"Declared events" states: engine config holds only engine namespaces; a plugin declares the events it emits in its own manifest. `eb_compose_known_types` already enforces the composition, so the composed known set is correct. What is missing is the structural test that the two legs never overlap.

**Decision.**
1. Replace `_PLUGIN_NS_RE` in the coverage test with a runtime-derived namespace set: scan all `plugins/*/*/manifest.yaml` files for `provides.events`, extract their namespace prefixes, remove every prefix that ADR-001 names as engine-owned (including `plugin`, which covers the `plugin.pr_open.*` exception naturally — `plugin.*` is filtered out of the manifest-derived set so the engine's legitimate `plugin.*` events are never flagged). Check that `config/event-schema.json` declares no event in the remaining plugin-owned namespaces.
2. Add a new assertion (R3): for each manifest, every declared event's namespace must NOT be in the ADR-001 engine namespace list, with the narrow exception of `plugin.pr_open.*` events in `plugins/tool/pr-open` (the documented ADR-001 exception).
3. Remove the 11 persist.*/hydrate.* entries from `config/event-schema.json` — they are already correctly declared in `plugins/tool/persist/manifest.yaml` and `plugins/tool/hydrate/manifest.yaml` and belong only there.
4. Remove `plugin.result` from `plugins/agent/security-lens/manifest.yaml` and `plugins/tool/merge/manifest.yaml` — it is an engine event declared centrally.
5. Add `## Enforced by` to ADR-001 and remove it from `config/adr-enforcement-baseline.txt`.

The `tests/golden/parity/event-sequence.golden` does not change: persist.* and hydrate.* events are still emitted by their plugins and still known via the manifest leg of the composed set; the sequence is identical.

```scope
tests/unit/event-schema-emitted-coverage-test.sh
config/event-schema.json
plugins/agent/security-lens/manifest.yaml
plugins/tool/merge/manifest.yaml
docs/adr/ADR-001-plugin-contract.md
config/adr-enforcement-baseline.txt
tests/golden/parity/event-sequence.golden
config/shape-change-paths.txt
```

```acceptance
SPEC-1[code]: The event-schema coverage test derives plugin-owned namespace prefixes from plugins/*/*/manifest.yaml at test time and fails when config/event-schema.json declares any event in one of those prefixes covers: R-1
SPEC-2[code]: The event-schema coverage test fails when any plugin manifest declares an event whose namespace is engine-owned, excepting plugin.pr_open.* in plugins/tool/pr-open covers: R-1
SPEC-3[code]: config/event-schema.json contains no entry under known_types beginning with "persist." covers: R-1
SPEC-4[code]: config/event-schema.json contains no entry under known_types beginning with "hydrate." covers: R-1
SPEC-5[code]: plugins/agent/security-lens/manifest.yaml contains no "plugin.result" entry under provides.events covers: R-1
SPEC-6[code]: plugins/tool/merge/manifest.yaml contains no "plugin.result" entry under provides.events covers: R-1
SPEC-7[no-code]: docs/adr/ADR-001-plugin-contract.md has an "## Enforced by" section naming tests/unit/event-schema-emitted-coverage-test.sh, and config/adr-enforcement-baseline.txt no longer lists ADR-001-plugin-contract.md covers: R-1
WIRING:
tests/unit/event-schema-emitted-coverage-test.sh
scripts/lib/lint-adr-enforced-by.sh
TESTFILES:
SPEC-1: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-2: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-3: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-4: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-5: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-6: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-7: tests/unit/lint-adr-enforced-by-test.sh
```

## Findings

No prior-stage findings to report; this is the first design pass. The only scope question was whether `tests/golden/parity/event-sequence.golden` needs updating: it does not, because the events removed from the engine config are already declared in the plugin manifests, the composed known set is unchanged, and the plugins' emit sites are untouched.
