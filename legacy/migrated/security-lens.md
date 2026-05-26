# security-lens — Migration in progress (NOT pruned)

> **Important:** This file is **not a completed tombstone**. ADR-002 §pruning
> protocol requires `git rm` of the legacy source before a migration is
> "done." Legacy source is still present (see below) and 2/5 trial items
> remain unchecked. This file documents work-in-progress, not completed
> migration. When the remaining trial items pass, the legacy source gets
> `git rm`'d and this file is rewritten as the actual tombstone (with a
> closing date and the merge SHA).

POC plugin port landed at `plugins/agent/security-lens/` on 2026-05-24.

## Source range — STILL PRESENT in legacy/

The following lines will be removed (via `git rm` on the file, or by
excising the cited ranges) when the migration completes:

- `legacy/scripts/lib/compound-audit.sh:48-53` (prompt block)
- `legacy/scripts/lib/compound-audit.sh:367` (trigger keywords)

## Current status

Phase 0 wiring complete: prompt + manifest + chokepoint + event-bus + 16/16
tests passing. LLM routing stub remains; real router lands in Phase 1.

## 5-test trial progress (3/5)

- [x] Behavior preserved: prompt text matches legacy:48-53 verbatim (verified by test)
- [x] Regression test exists: `tests/integration/plugin-security-lens-test.sh`
- [x] Legacy citation discoverable: `legacy/scripts/lib/compound-audit.sh:48-53` still present
- [ ] Mapping matches: KEEPERS §F row "compound-audit 7-lens cascade" — verify after manifest reconciliation lands
- [ ] Removal reproduces symptom: requires full pipeline orchestration (Phase 1)

## Promotion to actual tombstone

When the two unchecked items pass:
1. `git rm legacy/scripts/lib/compound-audit.sh` (or excise the cited ranges)
2. Rewrite this file as `tombstone: security-lens — migrated <date> via <PR>`
3. Drop the in-progress preamble; preserve the trial checklist as historical record.
