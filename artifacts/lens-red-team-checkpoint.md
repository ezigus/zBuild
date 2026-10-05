# Red-team lens checkpoint — issue #2035

## Files read
- `tests/unit/adr-migration-claims-test.sh` — new SPECs 1–6 added; SPEC-3 grep pattern fixed to exclude comments
- `docs/adr/ADR-028-shared-llm-agent-framework.md` — stale "not migrated" paragraph replaced with dated correction note
- `plugins/agent/review-lens/plugin.sh` — line 394 has a comment mentioning `extract_first_json_object`; no code calls

## Conclusions reached

1. **SPEC-1 regex is narrow (introduced):** `\*\*not\*\*.*migrat` catches only markdown-bold "not". A plain-text stale claim ("review-lens is not migrated") would escape. Low severity — the ADR now uses plain text in its correction note ("described them as not migrated", line 193) and the test correctly does not catch that (it's a past-tense correction). Future stale claims using plain text would also escape.

2. **SPEC-4 silently skips if plugin.sh absent (introduced):** `if [[ -f "$_rl_guard" ]]; then ... fi` with no else emits no assertion on file absence. Mitigated: SPEC-2 already uses grep-on-path with `2>/dev/null` (no -f guard), so it would `assert_fail` if plugin.sh were deleted.

3. **`basename | grep` on line 166 is pre-existing SIGPIPE pattern (not introduced):** This existed before this change (in the SPEC-4 retired-ADR block). Not introduced by this diff.

4. **No SIGPIPE violations in the newly introduced lines** — all new greps operate directly on files.

5. **No security vulnerabilities introduced** — this is purely documentation + test guard update. No code execution paths, no model calls, no user input handling.

## What I would do next
- Done. Emit the JSON.
