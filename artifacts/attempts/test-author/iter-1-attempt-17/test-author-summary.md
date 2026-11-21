## test-author — unusable

- changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TAFND-1: done — Removed the `if grep -Fxq "core/claim/claim.sh" "$REPO_ROOT/config/shape-change-paths.txt"` block (and its `assert_pass`/`assert_fail` lines) from `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`. No SPEC asks for this entry.
- answered: TAFND-2: done — Same removal as TAFND-1; the else-branch of the shape-change-paths.txt check was part of the same block, removed together.
- answered: build-tests finding 1: done — Explicit guarded `source "$REPO_ROOT/core/claim/claim.sh"` was added after `source plugin.sh` in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` in the previous iteration (iteration 9). It is still present in the file (lines 30–38).
- answered: acceptance-gate-test finding 1: not mine — No SPEC in this contract asks for `core/claim/claim.sh` to be listed in `config/shape-change-paths.txt`. The finding asks for a test of a change to `config/shape-change-paths.txt` that no SPEC requires. TAFND-1 and TAFND-2 (my own findings) confirm those assertions must be removed. The shape-change-paths.txt entry is an implementation decision; if a SPEC or design step required it, the design stage would have stated it.
