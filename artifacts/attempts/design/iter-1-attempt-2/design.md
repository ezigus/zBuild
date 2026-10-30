# Design — #1951: Fix enumerated guard in event-schema coverage test

## Architectural decision summary

**Goal.** The guard in `tests/unit/event-schema-emitted-coverage-test.sh` that
prevents plugin-owned namespaces from appearing in `config/event-schema.json` is
itself a hardcoded enumerated list (`_PLUGIN_NS_RE`). It omitted `persist` and
`hydrate`, so those plugins' events were double-declared in the engine config and
the guard never caught them. Two plugins (`security-lens`, `merge`) also
incorrectly claimed the engine event `plugin.result` in their manifests; the
guard had no path to catch that direction at all.

**Context.** ADR-001 §"Declared events": engine config holds only engine
namespaces; each plugin declares the events it emits in its own manifest.
`eb_compose_known_types` enforces composition at runtime, so the composed set is
correct. What is missing is a structural test that the engine-config leg and the
manifest leg never overlap, enforced from the manifest data rather than a
hand-maintained regex.

**Decision.**
1. Replace `_PLUGIN_NS_RE` in the coverage test with a runtime-derived set:
   scan all `plugins/*/*/manifest.yaml` for `provides.events`, extract namespace
   prefixes (part before the first `.`), then remove every prefix that ADR-001
   names as engine-owned (`plugin`, `pipeline`, `stage`, `stage_io`, `cycle`,
   `router`, `loop`, `state`, `registry`, `parallel`, `redaction`, `template`,
   `strategy`, `artifact`, `model`, `cost`, `orch`, `memory`, `backend`,
   `detection`, `llm`, `selfhost`). Filtering `plugin` out naturally handles the
   documented `plugin.pr_open.*` exception. Assert that
   `config/event-schema.json` has no `known_types` entry in any of the remaining
   plugin-owned prefixes.
2. Add a reverse assertion: for each manifest, every declared event's namespace
   prefix must not be engine-owned. The single narrow exception (`plugin.pr_open.*`
   from `plugins/tool/pr-open`) is handled by checking that `plugin.*` events
   only appear in that one path.
3. Remove the 11 `persist.*`/`hydrate.*` entries from `config/event-schema.json`
   — already correctly declared in the respective plugin manifests and belonging
   only there.
4. Remove `plugin.result` from `plugins/agent/security-lens/manifest.yaml` and
   `plugins/tool/merge/manifest.yaml` — it is an engine event, not
   plugin-declared.
5. Add `## Enforced by` to ADR-001 and remove it from
   `config/adr-enforcement-baseline.txt`.

`tests/golden/parity/event-sequence.golden` is unaffected: persist.* and
hydrate.* events remain known via the manifest leg of the composed set; only the
redundant engine-config leg is removed. The sequence is identical.

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
SPEC-1[code]: The event-schema coverage test exits non-zero when event-schema.json's known_types contains an event whose namespace prefix appears in any plugin manifest's provides.events (e.g., persist.start in event-schema.json) covers: R-1
SPEC-2[code]: The event-schema coverage test exits non-zero when any plugin manifest's provides.events contains an event whose namespace prefix is engine-owned per ADR-001 (e.g., plugin.result in the security-lens manifest) covers: R-1
SPEC-3[no-code]: persist.* and hydrate.* entries are removed from config/event-schema.json known_types; their canonical declarations remain only in the plugin manifests covers: R-1
SPEC-4[no-code]: plugin.result is removed from plugins/agent/security-lens/manifest.yaml and plugins/tool/merge/manifest.yaml provides.events covers: R-1
SPEC-5[no-code]: docs/adr/ADR-001-plugin-contract.md has an ## Enforced by section naming tests/unit/event-schema-emitted-coverage-test.sh, and config/adr-enforcement-baseline.txt no longer lists ADR-001-plugin-contract.md covers: R-1
WIRING:
tests/unit/event-schema-emitted-coverage-test.sh
TESTFILES:
SPEC-1: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-2: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-3: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-4: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-5: tests/unit/lint-adr-enforced-by-test.sh
```

## Findings

**SPEC-3/4/5/6 [code] → [no-code].** The validator correctly rejected the four
SPECs: removing entries from `event-schema.json` and plugin manifests is
data/config cleanup, not executable code. The rule "not what a file contains"
applies only to `[code]` requirements; `[no-code]` requirements describe docs,
config, or refactor work, which these are. The previous SPEC-7 (`[no-code]` for
ADR-001 Enforced by) was accepted with the same form — confirming the fix.
Renumbered as SPEC-3 through SPEC-5 with SPEC-3+4 each consolidating two
formerly separate entries that touched the same kind of change.

**tests/golden/parity/event-sequence.golden.** No change: persist.*/hydrate.*
events remain in the composed known set via plugin manifests; only their
redundant engine-config entry is removed.

**tests/unit/plugin-lifecycle-event-balance-test.sh.** Unaffected: that test
asserts `plugin.result` IS in `event-schema.json`. This change removes
`plugin.result` only from two plugin manifests, not from the engine config.
