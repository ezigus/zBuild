# FROZEN — DO NOT RUN

This directory is a **read-only reference copy** of shipwright, imported into zBuild on **2026-05-24**. It exists only so that:

1. The Keepers Spec citations (`legacy/scripts/<file>:<line>`) resolve.
2. Migration PRs can reference and `git rm` exact legacy sources as keepers verify out.
3. Tests can spin up fixture invocations of legacy code (via a wrapper that contains the blast radius).

## Do not run scripts under this directory.

The legacy CLI entry point (`legacy/scripts/sw`) has been **patched in one place only** to refuse to start when `legacy/.shipwright-disabled` exists. This is the sole exception to "preserve legacy verbatim." See [ADR-002](../docs/adr/ADR-002-legacy-import-strategy.md).

If you bypass the sentinel, the daemon will:
- Resolve `PROJECT_ROOT` via `git rev-parse --show-toplevel` → **zBuild repo root**.
- Write state to `zBuild/.claude/pipeline-state.md`.
- Claim labels in zBuild's GitHub issues.
- Append to global `~/.shipwright/events.jsonl`.

None of that is what you want.

## Legitimate (rare) reasons to run a legacy script

Generating a fixture for a 5-test trial. In that case use the wrapper:

```bash
(cd legacy && \
 PROJECT_ROOT="$(pwd)" \
 SHIPWRIGHT_HOME="$(pwd)/.shipwright-legacy" \
 SHIPWRIGHT_OVERRIDE_DISABLED=1 \
 ./scripts/sw <args>)
```

The override env var is recognized only when the sentinel still exists, preventing accidental enablement.

## Pruning

When a keeper from [KEEPERS.md](../docs/KEEPERS.md) passes its 5-test trial:

1. `git rm` the legacy source files for that keeper.
2. Create `legacy/migrated/<keeper-id>.md` with one line:
   ```
   <keeper-id> migrated to <new-path> on <YYYY-MM-DD> (issue #<N>)
   ```
3. Commit both as one commit: `migrate: <keeper> → <path>, remove legacy sources`.

`ls legacy/migrated/` answers "what's done." `legacy/` shrinks to zero by end-of-migration.
