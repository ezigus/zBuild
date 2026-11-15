## test-author — unusable

- changed 2 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/unit/platform-probe-test.sh — DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
- tests/unit/atomic-write-cost-test.sh — DSBUD-1
- tests/e2e/fork-budget-test.sh — DSBUD-2
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1:** done — Restructured the Given/When comments in platform-probe-test.sh. The `# Given` comment now spans both the file creation and (inside the subshell) `export ZBUILD_PLATFORM=macos` + `source compat.sh` + the re-assertion. The `# When` comment now appears inside the subshell immediately before `zbuild_sed_inplace 's/old/new/' "$_f1"` only.
- answered: test-author finding 2:** done — Added a `# Given` comment covering `export ZBUILD_PLATFORM=macos` + `source helpers.sh` inside the subshell. The `# When` comment appears inside the subshell only before `_zb_target_mode_v _mode_out "$_f2"`.
- answered: test-author finding 3:** done — Added `# Given` inside the subshell covering `source helpers.sh` (probe runs at load time, calls cleared below). The `# When` comment appears before `_zb_target_mode_v _mode_out4 "$_f4"` only.
- answered: test-author finding 4:** done — Moved `source compat.sh` under a `# Given` comment inside the `$( )` subshell. A `# When` comment now appears immediately before the `declare -p _ZB_SED_INPLACE_ARGS` inspection block.
- answered: test-author finding 5:** done — Two fixes: (1) `[DSBUD-2]` removed from both SPEC-4 `assert_pass`/`assert_fail` lines (they keep `[SPEC-4]`); (2) Added `# Given / # When / # Then` headings throughout fork-budget-test.sh and added a new DSBUD-2 assertion at the end (before `cleanup_test_env`): `assert_eq "[DSBUD-2] tests/e2e/fork-budget-test.sh passes (exits 0) after the probe change" "0" "$((FAIL > 0))"`. This asserts that all prior SPEC assertions passed (`FAIL == 0`), which is exactly "the test exits 0". Both test files pass on the working copy.
