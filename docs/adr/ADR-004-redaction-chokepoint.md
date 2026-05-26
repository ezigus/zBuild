# ADR-004: Redaction Chokepoint

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy scope-redaction safety primitive is invoked from **9 distinct call sites** today (verified in KEEPERS §C corrections). Every site calls `_redact_paths_outside_scope` directly with inline allowlist and cycle parameters. No wrapper function exists.

This is the highest-leverage safety mechanism in the system: it prevents an LLM agent from being shown paths it shouldn't see (out-of-scope files, sibling repos, credentials elsewhere on disk). Today's pattern works but is fragile — a new prompt-emitting code path can be added without going through redaction, and nothing in CI catches it.

Examples of what could leak without redaction:
- A scope-violation in a `find_files` output containing absolute paths.
- An adversarial diff fed into a security-lens prompt that includes paths outside the design's scope manifest.
- A git diff emitted into a developer-simulation prompt where the diff straddled a scope boundary.

## Decision

zBuild has **one** function that emits LLM-bound text. All 9 (or however many in the future) prompt sites pass through it.

### The chokepoint

```bash
core/redaction/apply_scope_redaction()
```

Signature (bash):
```bash
apply_scope_redaction <text_var> <scope_manifest_path> <allowlist_csv> <cycle_id>
```

Behavior:
1. **Refuse to emit** if `scope_manifest_path` is unset, empty, or unreadable. Emit synthetic blocking finding via event bus; return non-zero. (Fail-closed; absent evidence IS blocking evidence.)
2. Strip absolute and repo-relative paths outside the allowlist + scope-manifest entries.
3. Replace with `<out-of-scope-context>...</out-of-scope-context>` markers; preserve code-fence boundaries verbatim.
4. Emit `redaction.applied` event with `{prompt_size, redactions_count, scope_hash, cycle_id}`.
5. Idempotent — running twice produces identical output. Detected by a content hash on the wrapped output.

### Enforcement

- **Test:** `tests/unit/redaction-chokepoint-test.sh` greps the repo for `<claude\|<curl.*anthropic` invocations outside `core/redaction/` and `core/router/`; any match fails the test. (Per ADR-012, this lives in `tests/unit/` because it's a static repo scan, not an end-to-end integration.)
- **Code review:** PR checklist includes "Does this PR introduce a new LLM call?" → if yes, "Does it go through `core/redaction/apply_scope_redaction`?"
- **Manifest:** plugins MUST declare `requires.core: [redaction]`; the registry refuses to load a `kind: agent` plugin without it.
- **Event-bus assertion:** every `model.route` event MUST be preceded by a `redaction.applied` event within the same `run_id` + `stage`. The engine refuses to call the router if the precondition is unmet.

### Scope manifest contract

The scope manifest is a fenced markdown block in `design.md` (or runtime equivalent). Format:

```markdown
## Scope

\`\`\`scope
+ path/to/included/dir/
+ path/to/specific/file.ts
- path/to/excluded/dir/
\`\`\`
```

Parsed in one line of awk. Humans edit visually; engine reads the fence content as the authoritative allowlist.

### Operator override (audit-trail required)

In rare cases an operator may need to disable redaction for a debug run. This requires BOTH:
1. `ZBUILD_SCOPE_OVERRIDE=1` env var.
2. A token file at `~/.zbuild/scope-override-token` containing the current pipeline's `run_id`.

The token file must be written by the operator manually each run (one-shot). The agent CANNOT self-grant the override. Every override emits a `redaction.refused.overridden` event with operator-identifying metadata.

## Consequences

**Good:**
- One place to audit. One place to test. One place to extend (when we add ANSI-strip-on-emit or PII detection).
- New prompt sites can't accidentally bypass.
- Failure mode (refuse-to-emit on missing manifest) is fail-closed by default.
- Operator override is observable in event log.

**Bad:**
- Plugin authors must always go through the helper, even for "obviously safe" prompts. Friction. Mitigation: the helper is one function call.
- Tests grep for raw model invocations; clever obfuscation (e.g., constructing the URL via variable substitution) could bypass. Accepted; we're guarding against accidents, not adversaries.

## References

- [KEEPERS.md §C](../KEEPERS.md#section-c--reliability--safety-expanded) — redaction has 9 prompt seams; no wrapper today.
- `legacy/scripts/lib/helpers.sh:634-800` — original `_redact_paths_outside_scope` implementation (reference for the new chokepoint).
- `legacy/scripts/lib/pipeline-stages.sh:42` — scope-manifest extraction.
