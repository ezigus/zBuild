[bug] the guard against enumerated event lists is itself an enumerated list — two plugins leaked back into engine config and it passed

## Goal

The guard that keeps plugin-owned events out of the engine's event list works out for itself which events plugins own. It does not rely on its own hand-written list, which can go stale.

## What is wrong today

- In `tests/unit/event-schema-emitted-coverage-test.sh` (SPEC-1717-2), `_PLUGIN_NS_RE` is a hardcoded list of plugin namespaces. It is the kind of enumerated list the guard exists to prevent, and it already missed two leaks.
- All 11 `persist.*` and `hydrate.*` events are declared both in `config/event-schema.json` and in their plugins' manifests.
- `plugin.result` is declared in `plugins/agent/security-lens/manifest.yaml` and `plugins/tool/merge/manifest.yaml`, but it is an engine event.

## ADR

ADR-001, "Declared events": a plugin declares the events it owns in its manifest, and the engine's list holds only engine events. Add this test to ADR-001's Enforced-by entry.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** The guard derives plugin-owned namespaces from the plugin manifests (`plugins/*/*/manifest.yaml`), **excluding ADR-001's engine namespaces**, and fails when `config/event-schema.json` declares any of them.
- **R2.** `plugin.pr_open.*` is the one allowed exception (ADR-001), and only for `plugins/tool/pr-open`. A naive rule ("any namespace a manifest declares is plugin-owned") would wrongly mark all of `plugin.*`. The guard must not.
- **R3.** No plugin manifest declares an engine event (`plugin.result`, and the other engine namespaces).
- **R4.** The `persist.*` and `hydrate.*` entries are removed from `config/event-schema.json`. `plugin.result` is removed from the security-lens and merge manifests.
- **R5.** `_PLUGIN_NS_RE` is gone.

## Scope

- **Code/config:**
  - `tests/unit/event-schema-emitted-coverage-test.sh`
  - `config/event-schema.json`
  - `plugins/agent/security-lens/manifest.yaml`
  - `plugins/tool/merge/manifest.yaml`
- **ADR:** `docs/adr/ADR-001-plugin-contract.md` (Enforced-by line only).
- **In scope, no change expected:** `tests/golden/parity/event-sequence.golden`, and `config/shape-change-paths.txt` (lists the schema).
