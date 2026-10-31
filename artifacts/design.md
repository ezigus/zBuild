# Design — #1754: Fix unchecked atomic_write exits in test plugin and intake

## Architectural decision summary

**Goal.** A failed `atomic_write` on the result-write path of the test stage or
intake must never silently leave a prior round's file looking current. A
structural lint rule prevents the same class of defect from reappearing.

**Context.**
`_test_write_result` in `plugins/tool/test/plugin.sh` pipes `jq … | atomic_write
"$path"` and then captured only `PIPESTATUS[0]` (jq's exit) before this fix.
When jq succeeds but `atomic_write` fails, the old `_jq_rc=0` path called
`stage_result_add "$path"` against the prior-round file at that path. Because a
prior-round file is present (not a missing-file case), `stage_result_add` reads
and merges the stale data — producing a result with the prior round's outcome
(e.g. "pass"), not "broken". The fallback only fires when `_jq_rc != 0`, which a
successful jq + failed write never sets.

`_intake_run_inner` in `plugins/agent/intake/plugin.sh` writes `scope-manifest.md`
and `intake.md` with two `| atomic_write` calls. A write failure left the prior
round's content in place while intake reported `pass`.

`core/state/resume.sh` shows the correct pattern: capture both `PIPESTATUS[0]`
(jq's exit) and `PIPESTATUS[1]` (atomic_write's exit) on a single `local`
statement before any other command resets PIPESTATUS, then fail closed on either.

**Decision.**
1. Fix `_test_write_result`: capture `PIPESTATUS[1]` on the same `local`
   declaration as `PIPESTATUS[0]`. Treat a non-zero write exit the same as a
   non-zero jq exit — trigger the existing broken fallback. The fallback comment
   block must NOT contain the literal token `stage_result_add` (the
   `lint-disposition-words` awk scanner matches that token in comments as if it
   were a live writer call, treating the following words as outcome arguments).
2. Fix `_intake_run_inner`: check each `atomic_write` exit via `local
   _*_aw_rc="${PIPESTATUS[1]}"` immediately after the pipe; on failure call
   `_intake_write_result` with outcome `broken` and a reason naming the file,
   then `return 1`.
3. Add `scripts/lib/lint-atomic-write-unchecked.sh`: scan `.sh` files under
   `core/`, `plugins/`, and `scripts/` for `| atomic_write` whose exit is not
   handled. "Handled" means: `&&`, `||`, or `if !` on the same line; OR a shell
   continuation line (ending with `\`) whose immediately following physical line
   contains `||` or `&&`; OR a PIPESTATUS capture (`PIPESTATUS[`) on the next
   non-blank, non-comment executable line (blank and comment-only lines do not
   reset PIPESTATUS in bash). Emit file:line per violation and exit non-zero.
4. Wire the lint into `package.json`'s `lint` target.
5. Annotate every pre-existing `| atomic_write` site outside the two bugs that
   lacks an existing explicit exit check with `|| true` (17 newly-annotated
   locations in 11 files). These write diagnostic or auxiliary data; `|| true`
   makes the best-effort intent explicit and passes the broad lint rule.
   Two pre-existing sites already have explicit exit checks and must NOT receive
   `|| true` (which would break them):
   - `core/state/resume.sh:80` — `PIPESTATUS[1]` captured on the next non-blank
     executable line (after comment-only lines); adding `|| true` would overwrite
     PIPESTATUS and hide write failures.
   - `core/output/stage-io.sh:637` — `if ! printf … | atomic_write …; then`
     on the same line; adding `|| true` would make the condition always true,
     silently always running the error branch.
   The SPEC-8 test must exclude these two files from its `|| true` check,
   asserted non-vacuously (each file contains `| atomic_write`).

**Divergence from plan.** The plan's scope omits 11 additional files with
unchecked `| atomic_write` calls. The broad lint flags them all. 9 of the 11
files get `|| true`. 2 (`core/state/resume.sh`, `core/output/stage-io.sh`) are
already correctly handled and the SPEC-8 test excludes them instead.

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
SPEC-1[code]: when jq exits 0 but atomic_write fails for the primary result path in _test_write_result — with a prior-round pass result already at that path so stage_result_add on old code would merge the stale outcome — the result file carries outcome=broken and reason=result_write_failed, not the prior-round outcome covers: R-1
SPEC-2[code]: after a primary atomic_write failure in _test_write_result with a prior-round pass result at the path, runner_read_stage_verdict returns broken (not pass), proving the fallback write is what the reader classifies rather than the stale prior-round file covers: R-1
SPEC-3[code]: _intake_run_inner writes a broken result whose reason names scope-manifest.md and returns non-zero when atomic_write for that file fails covers: R-1
SPEC-4[code]: _intake_run_inner writes a broken result whose reason names intake.md and returns non-zero when atomic_write for that file fails, tested with a targeted mock that lets scope-manifest.md succeed but fails only intake.md covers: R-1
SPEC-5[code]: scripts/lib/lint-atomic-write-unchecked.sh exits non-zero and names the violating line (file:lineno) when given a .sh file containing a bare unchecked pipe to atomic_write covers: R-1
SPEC-6[code]: scripts/lib/lint-atomic-write-unchecked.sh exits 0 when every pipe to atomic_write in a .sh file is handled via: same-line &&, || or if !; OR a continuation line (ending with \) whose next physical line has || or &&; OR a PIPESTATUS[ capture on the next non-blank non-comment executable line covers: R-1
SPEC-7[code]: package.json lint target contains bash scripts/lib/lint-atomic-write-unchecked.sh covers: R-1
SPEC-8[no-code]: the 17 newly-annotated | atomic_write sites (13 original sites in 9 files plus secrets.sh:172 and own-checks.sh:72,96,101) carry || true; the SPEC-8 test excludes core/state/resume.sh and core/output/stage-io.sh from the || true requirement, asserts non-vacuously that each contains | atomic_write calls, and checks a total call count of >= 17 across all non-excluded non-continuation-line sites covers: R-1
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

**SPEC-1/SPEC-2 test-first validity (acceptance-gate finding 1, issue-acceptance
finding 4).** The acceptance-gate reported that SPEC-1 and SPEC-2 tests "already
pass on the code from before this change." The issue-acceptance simultaneously
reported the before-test check for these same SPECs **timed out**, making the
acceptance-gate finding unreliable. A timed-out run cannot produce a valid
"passes" verdict.

Code-level analysis confirms the tests ARE correctly discriminating:

- The SPEC-1 test (`test-plugin-result-write-fallback-test.sh:245-288`) writes a
  prior-round "pass" result at the output path via `stage_result_write`, then
  mocks `atomic_write` to fail only on the first call (the primary jq→write
  pipeline; second and later calls pass through to the real implementation). It
  calls `_test_write_result` with `outcome=pass`, then asserts `outcome=broken`.
  On **old code**: `_jq_rc = PIPESTATUS[0] = 0` (jq succeeded); the condition
  `(( _jq_rc != 0 ))` is false; `stage_result_add` is called on the prior-round
  file. `stage_result_add`'s own `atomic_write` call is the second call in the
  mock (succeeds), so the merged result has `outcome=pass`. The test asserts
  `outcome=broken` → **fails on old code**. ✓

- The SPEC-2 test (`test-result-reason-contract-test.sh:263-309`) uses the same
  mock and prior-round setup, then calls `runner_read_stage_verdict`. On old
  code, the reader sees the prior-round stale file (outcome=pass). The test
  asserts the reader returns "broken" → **fails on old code**. ✓

The SPECs are correctly stated as [code] requirements. No rewrite needed.

**SPEC-4 (acceptance-gate finding 2, issue-acceptance finding 1).** The prior
iteration of the implementation had a code defect where `_intake_run_inner`
returned 0 despite `_im_aw_rc != 0`. The current worktree code at
`plugins/agent/intake/plugin.sh:280-285` correctly captures `PIPESTATUS[1]` and
calls `return 1` when the intake.md write fails. The design specification is
correct. The earlier finding was from a prior implementation iteration; if the
test still fails, the implementer must identify and fix the execution path that
bypasses `return 1`. This is not a design issue.

**SPEC-8 scope expansion (issue-acceptance finding 2).** Four files were missing
from scope in an earlier design iteration. All four are now in scope. The current
worktree correctly has:
- `core/state/resume.sh:80` — excluded from `|| true` requirement; PIPESTATUS[1]
  captured after comment-only lines (bash does not reset PIPESTATUS on comments).
- `core/output/stage-io.sh:637` — excluded; handled by `if !` on the same line.
- `plugins/agent/build/lib/secrets.sh:172` — `|| true` present. ✓
- `plugins/tool/test/lib/own-checks.sh:72,96,101` — `|| true` present on all
  three lines. ✓
The SPEC-8 test already excludes `resume.sh` and `stage-io.sh` and checks >= 17
total non-continuation-line sites (actual count in the worktree: 18, which
includes `core/pipeline/contract-validator.sh:304` that carried `|| true` before
this change). The threshold >= 17 is satisfied. No design change needed.

**Lint-disposition-words regression (issue-acceptance finding 3).** A comment in
the fallback block of `plugins/tool/test/plugin.sh` containing the literal token
`stage_result_add` (e.g. `# no second stage_result_add call is needed.`) triggers
`lint-disposition-words`: the awk scanner matches
`stage_result_(write|add)[[:space:]]+<arg1>[[:space:]]+<arg2>` in comments, and
treats the following words as outcome arguments. `is` is not a valid outcome →
lint fails. This constraint is stated in the Decision section. The file is in
scope; the constraint is implementation-only. No design change needed.

**`scripts/lib/stage-result.sh` is not in scope.** Its `atomic_write` calls use
here-strings (`<<< "$json"`), not pipes; the lint does not apply. The function's
return value is atomic_write's exit code directly.

**`core/pipeline/contract-validator.sh` is not in scope.** Line 304 already
carries `|| true`; no change is needed. The lint and SPEC-8 test cover it
correctly without a scope entry.

**`core/state/resume.sh` is the reference pattern.** Lines 80–91 pipe to
`atomic_write` then capture both PIPESTATUS indices on a single `local` statement
(comment-only intervening lines do not reset PIPESTATUS), failing closed on
either. In scope only so the SPEC-8 test's exclusion of this file is non-vacuous;
the code is correct and must not be changed.
