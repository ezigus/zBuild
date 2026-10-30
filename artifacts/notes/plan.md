# Plan notes — issue #1951

## What the issue requires

Five requirements, all test-first:

- **R1**: Guard derives plugin-owned namespaces from `plugins/*/*/manifest.yaml`, excluding engine namespaces. Fails when `config/event-schema.json` declares any of them.
- **R2**: `plugin.pr_open.*` is the one allowed exception, only for `plugins/tool/pr-open`. Naive "any namespace a manifest declares" would wrongly mark all of `plugin.*`.
- **R3**: No plugin manifest declares an engine event (`plugin.result`, etc.).
- **R4**: Remove `persist.*` and `hydrate.*` from `config/event-schema.json`; remove `plugin.result` from security-lens and merge manifests.
- **R5**: `_PLUGIN_NS_RE` is gone from the test.

## File scope (updated after design stage)

- `tests/unit/event-schema-emitted-coverage-test.sh` — guard rewrite (R1, R2, R3, R5)
- `config/event-schema.json` — remove persist.* / hydrate.* (R4a)
- `plugins/agent/security-lens/manifest.yaml` — remove plugin.result (R4b)
- `plugins/tool/merge/manifest.yaml` — remove plugin.result (R4b)
- `plugins/agent/security-lens/tests/security-lens-test.sh` — remove [SPEC-16] sub-assertion that plugin.result IS in the manifest (R4b, design finding 2)
- `tests/unit/merge-v2-result-test.sh` — remove [SPEC-1] sub-assertion that plugin.result IS in the merge manifest (R4b, design finding 2)
- `docs/adr/ADR-001-plugin-contract.md` — add Enforced-by section
- `config/adr-enforcement-baseline.txt` — remove ADR-001 once Enforced-by is added (design finding: baseline only shrinks)

In-scope, no change expected: `tests/golden/parity/event-sequence.golden`, `config/shape-change-paths.txt`.

## Design findings that drove plan updates

**Finding 1 (two pre-existing tests break after step-4):** Removing `plugin.result`
from the security-lens and merge manifests makes `[SPEC-16]` in
`security-lens-test.sh` and `[SPEC-1]` in `merge-v2-result-test.sh` assert a
false fact (that plugin.result IS in those manifests). Without updating those
sub-assertions, step-4 leaves the suite broken. Step-4 now includes all four
files.

**Finding 2 (adr-enforcement-baseline.txt must shrink):** Adding `## Enforced by`
to ADR-001 requires removing ADR-001 from `config/adr-enforcement-baseline.txt`.
CLAUDE.md rules say the baseline "only shrinks." The lint enforces this. Step-5
now covers both files.

## Ordering logic

Test-first ordering requires:
1. Write tests that fail (step-1, step-2)
2. Then fix the data/config that makes them pass (step-3, step-4)
3. Then update ADR enforcement record (step-5)

step-1 and step-2 both touch the same test file, but test different requirements
and each has a distinct red-failure reason. They are ordered before their
respective fixes so the "write test, watch it fail" contract holds per
requirement group.

step-4 touches all four files together because the manifest change and the test
sub-assertion update are a single atomic action: leaving either half out breaks
the suite.

## Conclusion

5 steps cover all requirements. No open questions.
