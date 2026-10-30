# Plan notes — issue #1951

## What the issue requires

Five requirements, all test-first:

- **R1**: Guard derives plugin-owned namespaces from `plugins/*/*/manifest.yaml`, excluding engine namespaces. Fails when `config/event-schema.json` declares any of them.
- **R2**: `plugin.pr_open.*` is the one allowed exception, only for `plugins/tool/pr-open`. Naive "any namespace a manifest declares" would wrongly mark all of `plugin.*`.
- **R3**: No plugin manifest declares an engine event (`plugin.result`, etc.).
- **R4**: Remove `persist.*` and `hydrate.*` from `config/event-schema.json`; remove `plugin.result` from security-lens and merge manifests.
- **R5**: `_PLUGIN_NS_RE` is gone from the test.

## File scope

- `tests/unit/event-schema-emitted-coverage-test.sh` — guard rewrite (R1, R2, R3, R5)
- `config/event-schema.json` — remove persist.* / hydrate.* (R4a)
- `plugins/agent/security-lens/manifest.yaml` — remove plugin.result (R4b)
- `plugins/tool/merge/manifest.yaml` — remove plugin.result (R4b)
- `docs/adr/ADR-001-plugin-contract.md` — Enforced-by line only

In-scope, no change expected: `tests/golden/parity/event-sequence.golden`, `config/shape-change-paths.txt`.

## Ordering logic

Test-first ordering requires:
1. Write tests that fail (step-1, step-2)
2. Then fix the data/config that makes them pass (step-3, step-4)
3. Then update ADR enforcement record (step-5)

step-1 and step-2 both touch the same test file, but test different requirements and each has a distinct red-failure reason. They are ordered before their respective fixes so the "write test, watch it fail" contract holds per requirement group.

## Conclusion

5 steps cover all requirements. No open questions.
