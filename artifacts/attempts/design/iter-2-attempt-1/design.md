# Design — #1951: Fix enumerated guard in event-schema coverage test

## Architectural decision summary

**Goal.** The guard in `tests/unit/event-schema-emitted-coverage-test.sh` that
prevents plugin-owned namespaces from appearing in `config/event-schema.json` is
itself a hardcoded enumerated list (`_PLUGIN_NS_RE`, line 123). It omitted `persist`
and `hydrate`, so those plugins' events were double-declared in the engine config and
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
1. **Replace** the `[SPEC-1717-2]` block (lines 120–130 of the coverage test, which
   define and use `_PLUGIN_NS_RE`) with a manifest-derived guard: scan all
   `plugins/*/*/manifest.yaml` for `provides.events`, extract namespace prefixes
   (part before the first `.`), then remove every prefix that ADR-001 names as
   engine-owned (`plugin`, `pipeline`, `stage`, `stage_io`, `cycle`, `router`,
   `loop`, `state`, `registry`, `parallel`, `redaction`, `template`, `strategy`,
   `artifact`, `model`, `cost`, `orch`, `memory`, `backend`, `detection`, `llm`,
   `selfhost`). Assert that `config/event-schema.json` has no `known_types` entry
   whose namespace prefix is in the resulting manifest-derived set. The variable
   `_PLUGIN_NS_RE` must not remain in the file. Filtering `plugin` out naturally
   handles the `plugin.pr_open.*` exception.
2. Add a reverse assertion: for each plugin manifest, every declared event's
   namespace prefix must not be engine-owned. The single narrow exception
   (`plugin.pr_open.*` from `plugins/tool/pr-open`) is handled by checking that
   `plugin.*` events only appear in that one path.
3. Remove the 11 `persist.*`/`hydrate.*` entries from `config/event-schema.json`
   — already correctly declared in the respective plugin manifests.
4. Remove `plugin.result` from `plugins/agent/security-lens/manifest.yaml` and
   `plugins/tool/merge/manifest.yaml` — it is an engine event, not plugin-declared.
   Two tests that previously asserted `plugin.result` IS in those manifests must be
   updated to remove that sub-assertion: `[SPEC-16]` in `security-lens-test.sh`
   and `[SPEC-1]` in `merge-v2-result-test.sh`.
5. Add `## Enforced by` to ADR-001 and remove it from
   `config/adr-enforcement-baseline.txt`.

`tests/golden/parity/event-sequence.golden` is unaffected: persist.* and
hydrate.* events remain known via the manifest leg of the composed set; only the
redundant engine-config leg is removed.

```scope
tests/unit/event-schema-emitted-coverage-test.sh
config/event-schema.json
plugins/agent/security-lens/manifest.yaml
plugins/tool/merge/manifest.yaml
plugins/agent/security-lens/tests/security-lens-test.sh
tests/unit/merge-v2-result-test.sh
docs/adr/ADR-001-plugin-contract.md
config/adr-enforcement-baseline.txt
tests/golden/parity/event-sequence.golden
config/shape-change-paths.txt
```

```acceptance
SPEC-1[code]: The event-schema coverage test derives plugin-owned namespace prefixes dynamically from plugins/*/*/manifest.yaml provides.events rather than a hardcoded variable, and exits non-zero when event-schema.json's known_types contains an event in any manifest-derived namespace (e.g., persist.start) covers: R-1
SPEC-2[code]: The event-schema coverage test exits non-zero when any plugin manifest's provides.events contains an event whose namespace prefix is engine-owned per ADR-001 (e.g., plugin.result in the security-lens manifest) covers: R-1
SPEC-3[no-code]: persist.* and hydrate.* entries are removed from config/event-schema.json known_types; their canonical declarations remain only in the plugin manifests covers: R-1
SPEC-4[no-code]: plugin.result is removed from plugins/agent/security-lens/manifest.yaml and plugins/tool/merge/manifest.yaml provides.events, and the two tests that previously asserted plugin.result was present in those manifests are updated to remove that sub-assertion covers: R-1
SPEC-5[no-code]: docs/adr/ADR-001-plugin-contract.md has an ## Enforced by section naming tests/unit/event-schema-emitted-coverage-test.sh, and config/adr-enforcement-baseline.txt no longer lists ADR-001-plugin-contract.md covers: R-1
SPEC-6[no-code]: The hardcoded _PLUGIN_NS_RE variable and its associated guard block are absent from tests/unit/event-schema-emitted-coverage-test.sh after the change — no occurrence of _PLUGIN_NS_RE remains in the file covers: R-1
WIRING:
tests/unit/event-schema-emitted-coverage-test.sh
TESTFILES:
SPEC-1: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-2: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-3: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-4: tests/unit/event-schema-emitted-coverage-test.sh plugins/agent/security-lens/tests/security-lens-test.sh tests/unit/merge-v2-result-test.sh
SPEC-5: tests/unit/lint-adr-enforced-by-test.sh
SPEC-6: tests/unit/event-schema-emitted-coverage-test.sh
```

```supersedes
plugins/agent/security-lens/tests/security-lens-test.sh [SPEC-16]: manifest no longer declares plugin.result in provides.events (it is an engine event); the sub-assertion "manifest provides.events contains plugin.result" is now false and must be removed
tests/unit/merge-v2-result-test.sh [SPEC-1]: manifest no longer declares plugin.result in provides.events; the sub-assertion "manifest provides.events includes plugin.result" is now false and must be removed
```

## Findings

**Issue-acceptance finding 1 (`_PLUGIN_NS_RE` not removed).** The previous
build appended the new manifest-derived guard after the existing `_PLUGIN_NS_RE`
block rather than replacing it, leaving the hardcoded enumeration intact.
The design now explicitly states the `[SPEC-1717-2]` block (lines 120–130)
must be replaced — not augmented — and adds SPEC-6[no-code] requiring
`_PLUGIN_NS_RE` to be absent from the file after the change.

**Issue-acceptance finding 2 (two pre-existing tests fail).** Removing
`plugin.result` from the security-lens and merge manifests (SPEC-4) makes two
existing assertions wrong:
- `[SPEC-16]` in `plugins/agent/security-lens/tests/security-lens-test.sh`
  asserts `plugin.result` IS in the manifest.
- `[SPEC-1]` in `tests/unit/merge-v2-result-test.sh` asserts `plugin.result`
  IS in the merge manifest.

Both files are now in scope. Both are listed in the `supersedes` block. Both
are listed in SPEC-4's TESTFILES entry so the pipeline verifies they pass after
the sub-assertions are removed.

**tests/golden/parity/event-sequence.golden.** No change: persist.*/hydrate.*
events remain in the composed known set via plugin manifests; only their
redundant engine-config entry is removed.

**tests/unit/plugin-lifecycle-event-balance-test.sh.** Unaffected: that test
asserts `plugin.result` IS in `event-schema.json`. This change removes
`plugin.result` only from two plugin manifests, not from the engine config.

**SPEC-3/4/5/6 [no-code] rationale.** These require data/config/file changes
(not new code behaviour), so [no-code] is correct. The rule "not what a file
contains" applies only to [code] requirements.
