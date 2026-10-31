# Build notes — #1754

## What I found

### SPEC-1 / SPEC-2 fix (plugins/tool/test/plugin.sh)
- Line 1187: `| atomic_write "$path"` — primary write
- Line 1188: `local _jq_rc="${PIPESTATUS[0]}"` — only captures jq exit, not write exit
- Fix: capture both PIPESTATUS[0] and PIPESTATUS[1] in one `local` statement,
  then force `_jq_rc` non-zero when `_aw_rc != 0`.

### SPEC-3 / SPEC-4 fix (plugins/agent/intake/plugin.sh)
- Lines 273-274: two bare `| atomic_write` calls with no exit check
- Fix: capture PIPESTATUS[1] after each; on failure call `_intake_write_result`
  with outcome=broken, reason naming the file, then return 1.

### SPEC-5/6/7/8 (lint script + wire-in + 13 annotations)
- Create `scripts/lib/lint-atomic-write-unchecked.sh`:
  - No-arg mode: scans core/ plugins/ scripts/
  - File-arg mode: scans given files (for SPEC-5/6 fixture tests)
  - Checks: same-line &&/||/if !, continuation \+next-||/&&, next-exec-line PIPESTATUS[
  - Skip self (filename match)
  - SPEC-5: bare unchecked → non-zero exit + file:line output
  - SPEC-6: all 5 patterns → exit 0
- Wire into package.json lint target
- 13 pre-existing calls in 9 files get `|| true`:
  1. core/detect/platforms.sh:275,446
  2. core/pipeline/state_helpers.sh:43
  3. core/output/destinations.sh:39
  4. plugins/agent/pr-delivery/plugin.sh:117,253
  5. plugins/tool/merge/plugin.sh:229
  6. plugins/tool/output-github-comment/plugin.sh:103
  7. plugins/tool/test/lib/acceptance-check.sh:137,461
  8. plugins/tool/test/lib/acceptance-reason.sh:207,234
  9. plugins/tool/pr-open/plugin.sh:440
  (acceptance-reason.sh:218 already has \ + && on next line → skip)

### core/state/resume.sh — already correct
- Line 80: `| atomic_write --bak "$state_file"`
- Lines 81-90: ALL comments (no executable code)
- Line 91: `local _jq_rc="${PIPESTATUS[0]}" _write_rc="${PIPESTATUS[1]}"`
- Lint must skip blank/comment lines to find this PIPESTATUS → handled by design

## Status
- [ ] plugins/tool/test/plugin.sh — PIPESTATUS fix
- [ ] plugins/agent/intake/plugin.sh — atomic_write error checks
- [ ] scripts/lib/lint-atomic-write-unchecked.sh — create
- [ ] package.json — wire lint
- [ ] 13 files — add || true annotations
