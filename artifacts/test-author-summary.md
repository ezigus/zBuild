## test-author — fail

- changed 1 test file(s); 2 assertion(s) still do not test what their SPEC says after 2 round(s)

- SPECs in the contract: 8
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/unit/test-plugin-result-write-fallback-test.sh — SPEC-1
- tests/unit/test-result-reason-contract-test.sh — SPEC-2
- plugins/agent/intake/tests/intake-result-test.sh — SPEC-3, SPEC-4
- tests/unit/plugin-primary-output-atomic-test.sh — SPEC-5, SPEC-6, SPEC-7, SPEC-8
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 1: nothing to do — the test is correct; it asserts `_intake_run_inner` returns 1 and writes `outcome=broken` on intake.md write failure, which is exactly what SPEC-4 requires; the test fails because the implementation has not correctly checked the PIPESTATUS of the intake.md atomic_write call (issue-acceptance finding 1 confirms this), which is expected test-first behaviour**
- answered: test finding 2: nothing to do — this is an implementation regression in `plugins/tool/test/plugin.sh:1209` (a comment line that lint-disposition-words parses as a bad `stage_result_add` invocation); fixing that file is implementation work for another stage, not a test-author issue**
- answered: test finding 3: done — added exclusions for `core/state/resume.sh` and `core/output/stage-io.sh` in the SPEC-8 loop (these are "already handled" with PIPESTATUS per SPEC-8 text, not `|| true`, so they were falsely appearing as violations); changed count threshold from `>= 13` to `>= 17` per SPEC-8's explicit "13 original sites plus secrets.sh:172 and own-checks.sh:72,96,101" breakdown; the test still fails until the implementation annotates those 4 remaining sites, which is correct test-first behaviour**
- answered: test finding 4: nothing to do — the [G5] stage-signal failure is unrelated to issue #1754 and carries no #1754 tag; it is not my test**
- answered: acceptance-gate finding 1: nothing to do — the before-check timed out (acceptance-gate finding 3 confirms pipeline timeouts); my analysis of the old code path shows: on old code only `PIPESTATUS[0]` is captured so a failed atomic_write leaves `_jq_rc=0`, `stage_result_add` then writes `outcome=pass`, and the assertion `outcome=broken` gets "pass" which FAILS; issue-acceptance finding 4 independently reaches the same conclusion ("my reading of the old code logic supports the REQUIREMENTS assessment"); the test is falsifiable**
- answered: acceptance-gate finding 2: nothing to do — the test is correct; it fails because the implementation has not successfully fixed the intake.md write-check path (as confirmed by issue-acceptance finding 1); this is expected test-first behaviour, not a test defect**
- answered: acceptance-gate finding 3: nothing to do — this is a pipeline timeout, not a test issue**
- answered: acceptance-gate finding 4: nothing to do — this is a pipeline timeout, not a test issue**
- answered: test-author finding 1: done — changed the SPEC-8 count threshold from `>= 13` to `>= 17`; the 17 figure comes directly from SPEC-8's explicit enumeration (13 original sites in 9 files + secrets.sh:172 + own-checks.sh:72,96,101 = 17); this prevents an implementation that removes original calls while adding new ones from passing the count check**
- answered: test finding 1: nothing to do — SPEC-4's test is correct; it fails because the implementation returns 0 on intake.md failure (the bug the test is intended to expose, test-first)
- answered: test finding 2: nothing to do — the lint-disposition-words failure is in plugin.sh:1209, an implementation regression outside the test author's scope
- answered: test finding 3: done — prior round added the resume.sh/stage-io.sh exclusions in the loop; this round adds explicit assertions making the exclusion non-vacuous
- answered: test finding 4: nothing to do — stage-signal-test.sh [G5] is unrelated to issue #1754
- answered: acceptance-gate finding 1: nothing to do — the before-check timed out; old code cannot produce outcome=broken from a failed atomic_write because it only captures PIPESTATUS[0] (jq), not PIPESTATUS[1]; the assertions correctly distinguish old from new behavior
- answered: acceptance-gate finding 2: nothing to do — SPEC-4's test is correct; the implementation has the bug
- answered: acceptance-gate finding 3: nothing to do — the timeout on the before-check is a pipeline problem
- answered: acceptance-gate finding 4: nothing to do — the file-revert timeout is a pipeline problem
