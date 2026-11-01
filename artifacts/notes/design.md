# Design notes — issue #1754 (revision 8 — final verification pass)

## Verification pass (revision 8)

All claims verified against the current worktree. No changes to the design were needed.

### Evidence verified

- `plugins/agent/intake/plugin.sh:273` — `} | atomic_write "$state_dir/scope-manifest.md"` ✓
- `plugins/agent/intake/plugin.sh:274` — `local _sm_aw_rc="${PIPESTATUS[1]}"` ✓ (SPEC-3 [done] evidence confirmed)
- `plugins/agent/intake/plugin.sh:280-281` — `printf '%s\n' "$sanitized" | atomic_write "$state_dir/intake.md"` immediately followed by `local _im_aw_rc="${PIPESTATUS[1]}"` with NO debug printf between them — the SPEC-4 fix is in place ✓
- `core/state/resume.sh:80` — `| atomic_write --bak "$state_file"` with PIPESTATUS[1] captured at line 91 (after comment-only lines 81-90) — correctly excluded from || true ✓
- `core/output/stage-io.sh:637` — `if ! printf '%s\n' "$record" | atomic_write "$path"; then` — `if !` on same line; correctly excluded from || true ✓
- `plugins/tool/test/plugin.sh:1209-1210` — fallback uses `> "$path" 2>/dev/null || true` (direct redirect, no `| atomic_write`) — the SPEC-1/SPEC-2 fix is in place ✓

### Acceptance gate results

All 6 [code] SPECs: NEGCTL PASS
SPEC-3: NEGCTL SKIP (already_done) — correct
SPEC-8: NEGCTL SKIP (no_code) — correct
All 3 WIRING reachability checks: PASS
Issue-acceptance: pass (all 836 behavioral assertions pass)
Test stage verdict: fail — on performance only, not a stated issue requirement (confirmed by issue-acceptance summary)

### Conclusion

Design is complete and correct. No changes required from revision 7. design-draft.md written verbatim.

## Prior revision summary

### Revision 7 (key corrections)

- Corrected SPEC-1/SPEC-2 from [done] to [code]: the actual bug was in the fallback block (`| atomic_write && stage_result_add`), not in PIPESTATUS[1] capture. Tests needed all-fail mock.
- Corrected SPEC-3 from [code] to [done]: scope-manifest PIPESTATUS check was pre-existing and correct.
- Added `plugins/tool/test/plugin.sh` back to WIRING.
- Added SPEC-1/SPEC-2 TESTFILES entries.

### Revision 6

Marked SPEC-1/2 as [done] incorrectly (PIPESTATUS[1] was pre-existing, not the fix).

### Revision 5

Acceptance-gate found SPEC-1/SPEC-2 pass on old code, SPEC-4 mock broken.

### Revisions 1-4

Progressive refinement from initial bug analysis.

## Summary of the change

Two bugs fixed:
1. `plugins/tool/test/plugin.sh` fallback: `| atomic_write && stage_result_add` → `> "$path" 2>/dev/null || true` (direct redirect, bypasses any atomic_write mock)
2. `plugins/agent/intake/plugin.sh` intake.md PIPESTATUS: debug printf line that reset PIPESTATUS removed

New lint: `scripts/lib/lint-atomic-write-unchecked.sh` catches bare unchecked `| atomic_write` pipes.

17 sites across 11 files annotated with `|| true` (best-effort writes).
2 sites excluded: `core/state/resume.sh:80` (PIPESTATUS[1] on next non-blank executable line at line 91) and `core/output/stage-io.sh:637` (`if !` on same line).
