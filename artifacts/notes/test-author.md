# test-author notes — SPEC-correspondence judging pass

## What I read

1. `tests/unit/event-schema-emitted-coverage-test.sh` — lines 160–297 contain the
   SPEC-1 through SPEC-4 assertions. Both test files use `exit $((FAIL > 0))`, so
   any `assert_fail` call produces a non-zero exit.

2. `tests/unit/lint-adr-enforced-by-test.sh` — lines 152–176 contain the SPEC-5
   assertions (ADR_001_PC, awk-scoped section body search, BASELINE grep).

3. `scripts/lib/test-helpers.sh` — `assert_fail` increments FAIL; `assert_pass`
   increments PASS. FAIL is the exit determinant (`exit $((FAIL > 0))`).

## Per-SPEC conclusions

### SPEC-1 (current judgment)
Requirement: test exits non-zero when event-schema.json's known_types contains an event
whose namespace prefix appears in any plugin manifest's provides.events.

Assertion trace:
- Finds all plugin manifests under plugins/ (maxdepth 3).
- Collects plugin-provided events via eb_manifest_events.
- Extracts namespace prefixes (${_1951_pev%%.*}), deduplicates with sort -u.
- Iterates over $_engine_types (event-schema.json known_types):
  - Extracts namespace prefix of each type.
  - If prefix is in plugin-owned namespace set → adds to _1951_spec1_viol.
- Empty violations → assert_pass (exit 0).
- Non-empty violations → assert_fail per violation (exit non-zero).

This is a faithful implementation of the requirement. The example (persist.start) would
be caught if "persist" is a plugin-owned namespace. assert_fail triggers a non-zero exit.

→ corresponds

---

### SPEC-2 (current judgment)
Requirement: test exits non-zero when any plugin manifest's provides.events contains an event whose namespace prefix is engine-owned per ADR-001 (e.g., plugin.result in the security-lens manifest).

Assertion trace:
- Defines `_ENGINE_OWNED_NS_RE` covering: pipeline, stage, stage_io, plugin, cycle, router, loop, state, registry, parallel, redaction, template, strategy, artifact, model, cost, orch, memory, backend, detection, llm, selfhost.
- Scans all manifest.yaml files under plugins/ (maxdepth 3) via find -exec dirname.
- Extracts declared events via `eb_manifest_events`.
- For each event, checks if it matches `_ENGINE_OWNED_NS_RE` (engine-owned namespace prefix).
- Accumulates violations.
- If violations found → `assert_fail` (>> tagged) → FAIL++ → test exits non-zero.
- If no violations → `assert_pass` (>> tagged) → PASS++.

The regex includes `plugin` so `plugin.result` (the example in the requirement) would match.
The logic is complete and accurate for the stated requirement.

→ corresponds

---

### SPEC-3 (current judgment — THIS run)

Requirement: persist.* and hydrate.* entries are removed from config/event-schema.json
known_types; their canonical declarations remain only in the plugin manifests.

Two-clause requirement:
1. REMOVAL: persist.* and hydrate.* must be absent from config/event-schema.json known_types
2. CANONICAL SOURCE: their declarations must be present in (and only in) the plugin manifests

Assertion trace (four tagged checks):

A. Greps `_engine_types` (event-schema.json known_types) for ^persist\.
   → passes iff absent → establishes clause 1 for persist.*

B. Greps `_engine_types` for ^hydrate\.
   → passes iff absent → establishes clause 1 for hydrate.*

C. Reads plugins/tool/persist/manifest.yaml via eb_manifest_events, greps for ^persist\.
   → passes iff at least one persist.* event found → establishes clause 2 for persist.*

D. Reads plugins/tool/hydrate/manifest.yaml via eb_manifest_events, greps for ^hydrate\.
   → passes iff at least one hydrate.* event found → establishes clause 2 for hydrate.*

Clause 1 — A+B directly verify removal for both namespaces. ✓
Clause 2 — "remain only": the requirement names event-schema.json as the source being
  displaced; A+B confirm it is clear; C+D confirm the manifests carry the declarations.
  Together this is what "only in the plugin manifests" means in context. ✓

→ corresponds

---

### SPEC-4 (current judgment)

Requirement: plugin.result is removed from plugins/agent/security-lens/manifest.yaml and
plugins/tool/merge/manifest.yaml provides.events

Parsing the requirement:
- "plugin.result is removed from [A] and [B] provides.events"
- A = plugins/agent/security-lens/manifest.yaml (provides.events implied by context)
- B = plugins/tool/merge/manifest.yaml provides.events
- Both clauses: plugin.result must be absent from provides.events in both files.

(The only other reading — "remove from A; B continues to provide plugin.result" — would
make "B provides.events" an affirmative statement, contradicting the issue's stated
rationale that plugin.* is engine-owned and no plugin should claim it. The assertion
comments confirm the intent: "plugin.result is an engine-owned event; remove it from
provides.events" for both.)

Assertion trace:
1. eb_manifest_events on security-lens/manifest.yaml → grep -qxF "plugin.result".
   If found → assert_fail. If absent → assert_pass.
2. Same exact check on merge/manifest.yaml.

Both checks verify absence of plugin.result in provides.events for each respective
file — exactly what the requirement specifies for both parts.

→ corresponds

---

### SPEC-5 (current judgment — THIS run)

REQUIREMENT (three-part):
1. docs/adr/ADR-001-plugin-contract.md has an ## Enforced by section
2. That section names tests/unit/event-schema-emitted-coverage-test.sh
3. config/adr-enforcement-baseline.txt no longer lists ADR-001-plugin-contract.md

Assertion 1 (>> lines on assert_pass/fail after grep -q '## Enforced by'):
  Checks for the heading in ADR-001 → directly verifies requirement part 1.

Assertion 2 (>> lines on assert_pass/fail after grep of awk-extracted body):
  awk extracts lines between ## Enforced by and the next ## heading;
  grep -q 'event-schema-emitted-coverage-test.sh' <<< "$body"
  The filename must appear inside that section specifically, not just anywhere
  in the file. Directly verifies requirement part 2.

Assertion 3 (>> lines on assert_pass/fail after ! grep -q 'ADR-001' "$BASELINE"):
  Pattern 'ADR-001' is a prefix match on the baseline. Any entry for
  ADR-001-plugin-contract.md would contain it; functionally equivalent.
  Directly verifies requirement part 3.

All three requirement parts are covered. Passing all three establishes the
full requirement.

SPEC-5 VERDICT: corresponds
