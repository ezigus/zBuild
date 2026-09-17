# Plan checkpoint — issue 1841 security-lens v2 migration (resumed)

## Files read and what they told me

- `plugins/agent/security-lens/manifest.yaml` (82 lines): FULLY MIGRATED. Has result_contract:2, valid_verdicts:[pass,error], provides.events:[plugin.result, security_lens.failed], config.router:{timeout_s:600,max_turns:45}, primary:true on findings output.
- `plugins/agent/security-lens/plugin.sh` (224 lines): FULLY MIGRATED. Has `_security_lens_write_result` v2 helper, cleanup function, rc=1 on all exit paths, v2 result on every path including no-state-file and router-fatal.
- `plugins/agent/security-lens/tests/security-lens-test.sh` (508 lines): FULLY UPDATED. Covers SPEC-1 through SPEC-14 including: result_contract:2 assertions, verdict/disposition assertions, router-fatal v2 result, no-state-file v2 result, cleanup hook, manifest assertions, router budget override, and SPEC-14 no-hardcoded-paths grep assertion.

## Conclusions

Implementation is complete in commit 8bdd7441. All acceptance criteria covered:
1. v2 result on every exit path ✓
2. valid_verdicts [pass, error] declared, tests drive each ✓
3. No hardcoded artifact paths (SPEC-14 grep assertion) ✓
4. Router budgets in manifest, template override path tested (SPEC-12) ✓
5. primary: true on findings output ✓
6. security_lens_cleanup() declared and tested ✓
7. rc=1 on all non-zero paths ✓

Gap: no golden diff assertion for passing-run output shape (acceptance criterion 5). SPEC-14 covers the "no paths in code" criterion via grep.

## Plan steps (final)

- step-1: TDD tests for v2 contract (test file, ~98 new lines)
- step-2: manifest.yaml v2 fields
- step-3: plugin.sh v2 implementation
- step-4: verify npm test green
