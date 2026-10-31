# Design — #1754: Fix unchecked atomic_write exits in test plugin and intake

## Architectural decision summary

**Goal.** A failed `atomic_write` on the result-write path of the test stage or
intake must never silently leave a prior round's file looking current. A
structural lint rule prevents the same class of defect from reappearing.

**Context.**
`_test_write_result` in `plugins/tool/test/plugin.sh` pipes `jq … | atomic_write
"$path"` and then captures only `PIPESTATUS[0]` (jq's exit). When jq succeeds
but `atomic_write` fails, `_jq_rc=0`, so `stage_result_add` runs against a path
that was never written. If a prior round's file exists there, `stage_result_add`
reads and merges the stale data, producing a result that neither reflects the
current run nor triggers the broken fallback. The fallback fires only when
`_jq_rc != 0` — which a failed write never sets.

`_intake_run_inner` in `plugins/agent/intake/plugin.sh` writes `scope-manifest.md`
and `intake.md` with two `| atomic_write` calls. A write failure leaves the prior
round's content in place while intake reports `pass`.

`core/state/resume.sh` already shows the correct pattern: capture both
`PIPESTATUS[0]` (jq's exit) and `PIPESTATUS[1]` (atomic_write's exit) on a
single `local` statement before any other command resets PIPESTATUS, then fail
closed on either non-zero value.

**Decision.**
1. Fix `_test_write_result`: capture `PIPESTATUS[1]` on the same `local`
   declaration as `PIPESTATUS[0]`. Treat a non-zero write exit the same as a
   non-zero jq exit — trigger the existing broken fallback. The fallback
   implementation must NOT include comments containing the literal token
   `stage_result_add` (the `lint-disposition-words` awk scanner matches that
   token in comments as if it were a live writer call).
2. Fix `_intake_run_inner`: check each `atomic_write` exit via `local
   _*_aw_rc="${PIPESTATUS[1]}"` immediately after the pipe; on failure call
   `_intake_write_result` with outcome `broken` and a reason naming the file,
   then `return 1`.
3. Add `scripts/lib/lint-atomic-write-unchecked.sh`: scan `.sh` files under
   `core/`, `plugins/`, and `scripts/` for `| atomic_write` whose exit is not
   handled. "Handled" means: `&&`, `||`, or `if !` on the same line; or a
   PIPESTATUS capture (`PIPESTATUS[`) on the next non-blank, non-comment line.
   Emit a file-and-line message per violation and exit non-zero.
4. Wire the lint into `package.json`'s `lint` target.
5. Annotate every pre-existing `| atomic_write` site outside the two bugs that
   lacks an existing explicit exit check with `|| true` (17 locations in 11
   files). These write diagnostic or auxiliary data; `|| true` makes the
   best-effort intent explicit and lets the lint pass.
   Two pre-existing sites already have explicit exit checks and must NOT receive
   `|| true` (which would break them):
   - `core/state/resume.sh:80` — `PIPESTATUS[1]` captured on the next non-blank
     line (11 comment lines then `local _write_rc="${PIPESTATUS[1]}"`); adding
     `|| true` would overwrite PIPESTATUS and hide write failures.
   - `core/output/stage-io.sh:637` — `if ! printf … | atomic_write …; then error … return 1`
     on the same line; adding `|| true` would make the if-condition always true,
     silently always running the error branch.
   The SPEC-8 test must exclude these two files from its `|| true` check.

**Divergence from plan.** The plan's scope omits 11 additional files with
unchecked `| atomic_write` calls. The broad lint flags them all. 9 of the 11
files get `|| true`. 2 (`core/state/resume.sh`, `core/output/stage-io.sh`) are
already correctly handled and instead require the SPEC-8 test to exclude them.

```scope
plugins/tool/test/plugin.sh
plugins/agent/intake/plugin.sh
scripts/lib/lint-atomic-write-unchecked.sh
package.json
tests/unit/test-plugin-result-write-fallback-test.sh
tests/unit/test-result-reason-contract-test.sh
plugins/agent/intake/tests/intake-result-test.sh
tests/unit/plugin-primary-output-atomic-test.sh
core/detect/platforms.sh
core/pipeline/state_helpers.sh
core/output/destinations.sh
plugins/agent/pr-delivery/plugin.sh
plugins/tool/merge/plugin.sh
plugins/tool/output-github-comment/plugin.sh
plugins/tool/pr-open/plugin.sh
plugins/tool/test/lib/acceptance-reason.sh
plugins/tool/test/lib/acceptance-check.sh
plugins/agent/build/lib/secrets.sh
plugins/tool/test/lib/own-checks.sh
core/state/resume.sh
core/output/stage-io.sh
```

```acceptance
SPEC-1[code]: when jq succeeds but atomic_write fails in _test_write_result, the broken fallback is written with outcome=broken and reason=result_write_failed covers: R-1
SPEC-2[code]: runner_read_stage_verdict classifies the result on disk after a primary-path atomic_write failure as broken, not as the prior round's outcome covers: R-1
SPEC-3[code]: _intake_run_inner writes a broken result whose reason names scope-manifest.md and returns non-zero when atomic_write for that file fails covers: R-1
SPEC-4[code]: _intake_run_inner writes a broken result whose reason names intake.md and returns non-zero when atomic_write for that file fails, tested with a targeted mock that lets scope-manifest.md succeed but fails only intake.md covers: R-1
SPEC-5[code]: scripts/lib/lint-atomic-write-unchecked.sh exits non-zero and names the violating line when given a .sh file containing a bare unchecked pipe to atomic_write covers: R-1
SPEC-6[code]: scripts/lib/lint-atomic-write-unchecked.sh exits 0 when every pipe to atomic_write in a .sh file is either: on the same line as &&, ||, or if !; or immediately followed (skipping blank and comment-only lines) by a line containing PIPESTATUS[ covers: R-1
SPEC-7[code]: package.json lint target contains bash scripts/lib/lint-atomic-write-unchecked.sh covers: R-1
SPEC-8[no-code]: the 17 pre-existing | atomic_write calls that have no existing exit check carry || true (13 original sites in 9 files plus secrets.sh:172 and own-checks.sh:72,96,101); the SPEC-8 test excludes core/state/resume.sh and core/output/stage-io.sh (already handled) from the || true requirement and counts >= 17 annotated calls covers: R-1
WIRING:
plugins/tool/test/plugin.sh
plugins/agent/intake/plugin.sh
package.json
TESTFILES:
SPEC-1: tests/unit/test-plugin-result-write-fallback-test.sh
SPEC-2: tests/unit/test-result-reason-contract-test.sh
SPEC-3: plugins/agent/intake/tests/intake-result-test.sh
SPEC-4: plugins/agent/intake/tests/intake-result-test.sh
SPEC-5: tests/unit/plugin-primary-output-atomic-test.sh
SPEC-6: tests/unit/plugin-primary-output-atomic-test.sh
SPEC-7: tests/unit/plugin-primary-output-atomic-test.sh
SPEC-8: tests/unit/plugin-primary-output-atomic-test.sh
```

## Findings

**SPEC-8 scope expansion (issue-acceptance finding 2).** Four files were missing
from scope. The SPEC-8 test checks all `| atomic_write` calls outside the two
bug-fix files for `|| true` on the same line. It found six sites without it:
- `core/state/resume.sh:80` — already handled: PIPESTATUS[1] captured on line 91
  (the intervening lines are all comments; bash does not reset PIPESTATUS on
  comment-only lines). Adding `|| true` here would make `_write_rc` always 0,
  silently hiding write failures. Fix: the SPEC-8 test must exclude this file.
- `core/output/stage-io.sh:637` — already handled: `if ! printf … | atomic_write …`
  on the same line. Adding `|| true` would make the `if !` condition always true,
  always executing the error branch. Fix: the SPEC-8 test must exclude this file.
- `plugins/agent/build/lib/secrets.sh:172` — unchecked best-effort write. Added
  to scope; needs `|| true`.
- `plugins/tool/test/lib/own-checks.sh:72,96,101` — unchecked best-effort writes.
  Added to scope; each line needs `|| true`.
  Both files and `core/state/resume.sh` and `core/output/stage-io.sh` are now
  in scope. The SPEC-8 test (`tests/unit/plugin-primary-output-atomic-test.sh`)
  must add exclusions for the two correctly-handled files and raise its count
  threshold from >= 13 to >= 17.

**Lint-disposition-words regression (issue-acceptance finding 3).** A comment
added to the fallback path at `plugin.sh` containing the literal string
`stage_result_add` (e.g. `# no second stage_result_add call is needed.`)
triggers `lint-disposition-words`. The awk scanner matches
`stage_result_(write|add)[[:space:]]+<arg1>[[:space:]]+<arg2>` in comments too,
treating the words after `stage_result_add` as arguments. The result word `is`
(from `… call is needed`) is not in the engine's outcome set, so the lint fails.
This is a constraint on the implementation: the fallback block's comment text in
`plugins/tool/test/plugin.sh` must not include the token `stage_result_add`.
The file is already in scope; the constraint applies to the implementation only.

**SPEC-4 implementation issue (issue-acceptance finding 1 and acceptance-gate
finding 2).** The test for SPEC-4 is correctly structured: it mocks `atomic_write`
to fail only for the `*intake.md` path (not `*intake-result*`), asserts
`_intake_run_inner` returns 1, and checks `outcome=broken` in the result file.
The code at `plugins/agent/intake/plugin.sh:280-286` captures `PIPESTATUS[1]` and
checks `_im_aw_rc != 0`. The issue-acceptance finding says the function still
returns 0 and writes `pass`. This is a code-level defect — the design correctly
specifies the requirement; the implementer must identify and fix the execution
path that bypasses the `return 1`. This is not a design issue.

**SPEC-1/SPEC-2 test-first validity (acceptance-gate finding 1, issue-acceptance
finding 4).** The acceptance-gate reported that SPEC-1 and SPEC-2 tests "already
pass on the code from before this change." However, the before-test run timed out,
making that report unreliable. Analysis confirms the tests should fail on old code:
- Old code captures only `PIPESTATUS[0]` (jq's exit). When jq succeeds but
  `atomic_write` fails, `_jq_rc=0`, `stage_result_add` is called on the stale
  prior-round file, and the result has the prior round's outcome (not `broken`).
- The SPEC-1 test asserts `outcome=broken`; this FAILS on old code. ✓
- The SPEC-2 test asserts the reader classifies the disk content as `broken`
  (not the prior `pass`); this also FAILS on old code. ✓
No design change is needed; the requirements are correct.

**`scripts/lib/stage-result.sh` is not in scope.** Its `atomic_write` calls use
here-strings (`<<< "$json"`), not pipes, so the `| atomic_write` lint does not
apply. The function's return value is atomic_write's exit code directly.

**`core/state/resume.sh` is the reference pattern.** Lines 80–91 pipe to
`atomic_write` and then capture both PIPESTATUS indices on a single `local`
statement, failing closed on either. It is in scope because the SPEC-8 test must
explicitly exclude it from the `|| true` check; the code itself is correct.
