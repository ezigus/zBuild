security-lens (Phase 0 POC) migrated to plugins/agent/security-lens/ on 2026-05-24.

Source range (still present in legacy/, will be `git rm`'d at full migration):
- legacy/scripts/lib/compound-audit.sh:48-53 (prompt block)
- legacy/scripts/lib/compound-audit.sh:367 (trigger keywords)

Phase 0 status: prompt + manifest + chokepoint + event-bus wiring + 16/16 tests passing.
LLM routing stub remains until core/router/ lands (Phase 1).

5-test trial:
- [x] Behavior preserved: prompt text matches legacy:48-53 verbatim (verified by test)
- [x] Regression test exists: tests/plugin-security-lens-test.sh
- [x] Legacy citation discoverable: legacy/scripts/lib/compound-audit.sh:48-53 still present
- [ ] Mapping matches: KEEPERS §F row "compound-audit 7-lens cascade" — verify after issue manifest lands
- [ ] Removal reproduces symptom: requires full pipeline orchestration (Phase 1)

This tombstone gets a date update + issue reference when the trial completes.
