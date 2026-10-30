# Design notes — issue #1951

## What I read

- `tests/unit/event-schema-emitted-coverage-test.sh` — the test with the bug; `_PLUGIN_NS_RE` is at line 123, `[SPEC-1717-2]` block is lines 120-130
- `config/event-schema.json` — contains persist.* (6 events) and hydrate.* (5 events) that are double-declared
- `plugins/tool/persist/manifest.yaml` — correctly declares persist.* events; already the authoritative source
- `plugins/tool/hydrate/manifest.yaml` — correctly declares hydrate.* events
- `plugins/agent/security-lens/manifest.yaml` — wrongly declares `plugin.result` in provides.events
- `plugins/tool/merge/manifest.yaml` — wrongly declares `plugin.result` in provides.events
- `plugins/tool/pr-open/manifest.yaml` — declares `plugin.pr_open.*` events (allowed exception)
- `docs/adr/ADR-001-plugin-contract.md` — defines engine namespaces; §"Declared events"
- `config/adr-enforcement-baseline.txt` — ADR-001 is in the baseline (no Enforced by section yet)
- `tests/unit/lint-adr-enforced-by-test.sh` — A7 tests the real tree
- `tests/unit/plugin-lifecycle-event-balance-test.sh` — SPEC-3 checks `plugin.result` IS in event-schema.json (not affected by our change)
- `config/shape-change-paths.txt` — event-schema.json is in it (line 14); golden check applies
- `plugins/agent/security-lens/tests/security-lens-test.sh` — SPEC-16 (lines 553-565) checks `plugin.result` AND `security_lens.failed` are in manifest; will fail after SPEC-4
- `tests/unit/merge-v2-result-test.sh` — SPEC-1 (lines 42-54) checks `plugin.result` is in merge manifest; will fail after SPEC-4

## The bug (line 123 of coverage test)

```bash
_PLUGIN_NS_RE='^(intake|plan|design|impact|build|acceptance|...|claim)\.'
```
Missing: `persist` and `hydrate`. So `persist.*` and `hydrate.*` events in event-schema.json pass the check even though they're plugin-owned namespaces. The bug is self-referential: the guard that prevents enumerated lists is itself an enumerated list.

## Fix logic

**SPEC-1/SPEC-2 (rewrite guard, add reverse check):**
- Scan all `plugins/*/*/manifest.yaml` for `provides.events`
- Extract namespace prefix (part before first `.`) of each declared event
- Remove engine namespaces from that set (per ADR-001: plugin, pipeline, stage, stage_io, cycle, router, loop, state, registry, parallel, redaction, template, strategy, artifact, model, cost, orch, memory, backend, detection, llm, selfhost)
- The pr-open `plugin.pr_open.*` exception is naturally handled: `plugin.*` is engine-owned and gets filtered out
- Check event-schema.json has no `known_types` entries in any of the remaining manifest-derived namespaces
- Reverse direction: for each manifest, each declared event's namespace must NOT be engine-owned

**SPEC-3 (remove double-declared events from engine config):**
- Remove `hydrate.start`, `hydrate.complete`, `hydrate.fetch.failed`, `hydrate.restore.failed`, `hydrate.result.write_failed` from event-schema.json (5 events)
- Remove `persist.start`, `persist.complete`, `persist.push.failed`, `persist.push.refused`, `persist.snapshot.failed`, `persist.result.write_failed` from event-schema.json (6 events)
- NOTE: plugin.result STAYS in event-schema.json (it's an engine event)

**SPEC-4 (remove engine event from plugin manifests):**
- Remove `plugin.result` from security-lens and merge manifests

**SPEC-5 (ADR-001 Enforced by):**
- Add section to ADR-001 naming the test file
- Remove ADR-001 from config/adr-enforcement-baseline.txt

## Why previous design was rejected

The validator flagged SPEC-3, SPEC-4, SPEC-5, SPEC-6 (all [code]) with "describes what a file contains, not what the code does." The rule "not what a file contains" applies only to [code] requirements. These four are data/config cleanup — no executable code changes. The fix: reclassify them as [no-code].

Evidence: old SPEC-7 ([no-code], ADR-001 Enforced by section) had the same "file contains" form and was NOT rejected. Confirms [no-code] accepts config/data descriptions.

## Issue-acceptance findings addressed

**Finding 1 (_PLUGIN_NS_RE not removed):**
- Build stage appended new code after line 157 but never removed/replaced the old `[SPEC-1717-2]` block (lines 120-130)
- Decision section now explicitly says "Replace" the block, not augment
- Added SPEC-6[no-code] requiring `_PLUGIN_NS_RE` to be absent from the file after the change

**Finding 2 (two pre-existing tests fail):**
- `plugins/agent/security-lens/tests/security-lens-test.sh` [SPEC-16]: asserts plugin.result IS in manifest — will be wrong after SPEC-4
- `tests/unit/merge-v2-result-test.sh` [SPEC-1]: asserts plugin.result IS in merge manifest — will be wrong after SPEC-4
- Added both to scope
- Added supersedes block documenting both assertions
- Added both to SPEC-4's TESTFILES entry

## SPEC numbering in final design

- SPEC-1 [code]: guard rewrite (manifest-derived derivation of plugin namespaces)
- SPEC-2 [code]: reverse direction check (no engine events in manifests)
- SPEC-3 [no-code]: persist.*/hydrate.* removed from event-schema.json
- SPEC-4 [no-code]: plugin.result removed from two plugin manifests + two test updates
- SPEC-5 [no-code]: ADR-001 Enforced by section + baseline removal
- SPEC-6 [no-code]: _PLUGIN_NS_RE absent from coverage test file

## WIRING reasoning

The implementation (new guard) lives in `tests/unit/event-schema-emitted-coverage-test.sh`. The file that "calls" the behavior is the same file (the test exercises its own guard function). If reverted, SPEC-1/SPEC-2 assertions would fail. This is an edge case where implementation = test file.

For SPEC-5, the wiring is `config/adr-enforcement-baseline.txt` conceptually (removing ADR-001 from it causes the lint to enforce ADR-001), but a config list entry is not valid WIRING per the instructions. The test for SPEC-5 (`lint-adr-enforced-by-test.sh`) independently verifies ADR-001 has the section.

## Golden file check

`tests/golden/parity/event-sequence.golden` has hydrate.start, hydrate.complete, persist.start, persist.complete. These events will still be EMITTED (plugin code unchanged) and still be KNOWN (via manifest composition). Removing them from event-schema.json doesn't affect what events are known. No change to golden file needed.

## Test that might be fragile: plugin-lifecycle-event-balance-test.sh

Line 205-206 checks `plugin.result` IS in event-schema.json. Our change does NOT remove plugin.result from event-schema.json (only from the plugin manifests). So this test is unaffected.
