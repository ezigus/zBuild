# Design notes — issue #1754 (revision 6 — current)

## Summary of changes in revision 6

**SPEC-1 and SPEC-2: marked [done].**
Acceptance-gate finding 1 (both tests pass on "old code") confirmed the fix was
already in the worktree at `plugins/tool/test/plugin.sh:1188-1189` from a prior
iteration. Per the prompt instructions: when a test passes on old code and the
code already does it, mark [done] with evidence.

Evidence confirmed by reading the file:
- Line 1188: `local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"`
- Line 1189: `(( _aw_rc != 0 )) && _jq_rc="$_aw_rc"`

**SPEC-2 issue-acceptance finding 2 ("NOT SURE") resolved** by [done] marking.

**SPEC-4 finding is stale.** The intake test mock was fixed in the worktree
(lines 467-474 use `${_aw_target##*/}` == "intake.md"). The issue-acceptance
finding was from before that fix. SPEC-4 stays [code].

**WIRING: `plugins/tool/test/plugin.sh` removed.** With SPEC-1/SPEC-2 [done],
no [code] SPEC test would fail if that file is reverted. Only
`plugins/agent/intake/plugin.sh` and `package.json` remain in WIRING.

## Files read this revision

- `plugins/tool/test/plugin.sh:1185-1215` — PIPESTATUS[1] at lines 1188-1189 ✓
- `plugins/agent/intake/plugin.sh:115-302` — PIPESTATUS[1] at lines 274, 281 ✓
- `plugins/agent/intake/tests/intake-result-test.sh:440-500` — correct mock
  at lines 467-474, uses `${_aw_target##*/}` ✓
- `tests/unit/test-plugin-result-write-fallback-test.sh:237-290` — SPEC-1 test ✓
- `tests/unit/test-result-reason-contract-test.sh:263-310` — SPEC-2 test ✓

## Prior revision history (retained for context)

### Revision 5 — acceptance-gate finding 1, issue-acceptance findings 1+2

- Acceptance-gate finding 1: SPEC-1/SPEC-2 pass on old code (stale worktree)
- Acceptance-gate finding 2: SPEC-4 test doesn't pass on new code (mock broken)
- Issue-acceptance finding 1: SPEC-4 unmet (mock broken in submitted diff)
- Issue-acceptance finding 2: SPEC-2 "NOT SURE" (prior-round logic not in diff)

Design explained all as incomplete diffs. This revision (6) resolves them:
SPEC-1/SPEC-2 [done] (fix in worktree); SPEC-4 stale (mock fixed in worktree).

### Original bug analysis (revision 1)

- `plugins/tool/test/plugin.sh`: only `PIPESTATUS[0]` captured; jq success +
  atomic_write failure → `_jq_rc=0` → `stage_result_add` on stale file.
- `plugins/agent/intake/plugin.sh:273-274`: no exit check on either write.
- `core/state/resume.sh:80-91`: reference pattern (captures both indices).

### Additional `| atomic_write` sites (revision 2)

17 unchecked sites outside the two bugs:
- 9 files: core/detect/platforms.sh, core/pipeline/state_helpers.sh,
  core/output/destinations.sh, plugins/agent/pr-delivery/plugin.sh,
  plugins/tool/merge/plugin.sh, plugins/tool/output-github-comment/plugin.sh,
  plugins/tool/pr-open/plugin.sh, plugins/tool/test/lib/acceptance-reason.sh,
  plugins/tool/test/lib/acceptance-check.sh → get `|| true`
- 2 files excluded from `|| true`: core/state/resume.sh (PIPESTATUS[1] on next
  line), core/output/stage-io.sh (if ! on same line)
- 2 additional files: secrets.sh:172, own-checks.sh:72,96,101 → get `|| true`

### Lint-disposition-words constraint (revision 2)

Fallback comment in `plugins/tool/test/plugin.sh` must not contain the token
`stage_result_add` — the awk scanner matches it in comments.

### SPEC-2 text correction (revision 5)

`runner_read_stage_verdict` never returns "broken" (maps to "error").
`runner_read_stage_disposition` returns "broken" for outcome=broken.
SPEC-2 text corrected to name `runner_read_stage_disposition`.
