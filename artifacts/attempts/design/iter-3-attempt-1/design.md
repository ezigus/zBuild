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
SPEC-2[code]: after a primary atomic_write failure in _test_write_result with a prior-round pass result at the path, runner_read_stage_disposition returns broken (not complete), proving the fallback write is what the disposition reader classifies rather than the stale prior-round file covers: R-1
SPEC-3[code]: _intake_run_inner writes a broken result whose reason names scope-manifest.md and returns non-zero when atomic_write for that file fails covers: R-1
SPEC-4[code]: _intake_run_inner writes a broken result whose reason names intake.md and returns non-zero when atomic_write for that file fails; the test mock matches only the FILENAME (not the full path) via "${_aw_target##*/}" == "intake.md" so the test temp dir plugin-intake-result.XXXXXX does not suppress the failure; scope-manifest.md and intake-result.json writes go through the real implementation covers: R-1
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

**SPEC-1/SPEC-2 — incomplete diff (acceptance-gate finding 1, revised).**
The acceptance-gate finding this round is NOT due to a timeout. The code fix is
confirmed in the worktree at `plugins/tool/test/plugin.sh:1188`:
```
local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"
```
The most recently submitted diff only modified `test-result-reason-contract-test.sh`
(the SPEC-2 assertion). It did not include `plugins/tool/test/plugin.sh`. When the
acceptance-gate reverts the submitted diff to check "old code," it does not revert
the plugin fix — which is in the worktree from a prior iteration but outside the
diff. Old code therefore still has PIPESTATUS[1] captured, so both tests pass.

The tests ARE correctly discriminating: on code without line 1188's PIPESTATUS[1]
capture, SPEC-1's call-counter mock fails the primary write → old code falls
through to `stage_result_add` on the stale prior-round file → merged outcome=pass
→ test asserts broken → FAILS ✓. SPEC-2 similarly: without PIPESTATUS[1], the
stale outcome=pass is merged → `runner_read_stage_disposition` returns "complete"
→ test asserts "broken" → FAILS ✓.

Resolution: `plugins/tool/test/plugin.sh` is listed in WIRING. The pipeline's
WIRING check puts that file back to its old version (without PIPESTATUS[1]) and
verifies at least one test fails — which it does. The implementer must include
`plugins/tool/test/plugin.sh` in the submitted diff. No SPEC or test change needed.

**SPEC-4 — broken mock exclusion pattern (acceptance-gate finding 2,
issue-acceptance finding 1, revised).**
The previous design finding ("the SPEC-4 test is correct") was wrong.
The mock in `intake-result-test.sh:465-467` uses:
```bash
if [[ "$_aw_target" == *"intake.md" && "$_aw_target" != *"intake-result"* ]]; then
```
`setup_test_env "plugin-intake-result"` creates a temp dir named
`plugin-intake-result.XXXXXX`. From `intake-test-lib.sh`:
```
STATE_DIR="$TEST_TEMP_DIR/state"
```
The `intake.md` write path in the plugin is `$state_dir/intake.md` =
`/tmp/plugin-intake-result.XXXXXX/state/intake.md`. The path contains
`plugin-intake-result` which includes `intake-result` as a substring. So:
- `*"intake.md"` → TRUE (path ends in intake.md)
- `*"intake-result"*` → TRUE (path contains "intake-result" via dir name)
- `!= *"intake-result"*` → FALSE
- Condition: TRUE AND FALSE = FALSE → mock does NOT fail the write

Result: `_im_aw_rc` is 0 → plugin continues to return 0 → all three SPEC-4
assertions fail on both old and new code. This is why the acceptance-gate says
the test does not pass even on new code.

Fix specified in SPEC-4: the mock condition must match only on the filename, not
the full path:
```bash
if [[ "${_aw_target##*/}" == "intake.md" ]]; then
```
`basename("scope-manifest.md path")` = `scope-manifest.md` ≠ `intake.md` → passes ✓
`basename("intake.md path")` = `intake.md` = `intake.md` → fails ✓
`basename("intake-result.json path")` = `intake-result.json` ≠ `intake.md` → passes ✓

With the correct mock and new code (PIPESTATUS[1] at line 281): the write fails →
`_im_aw_rc=1` → broken result written, returns 1 → all three SPEC-4 assertions
pass. With old code (no PIPESTATUS[1]): write failure is undetected → plugin
returns 0, writes "pass" → assertions fail ✓.

This is a design specification: SPEC-4 text has been updated to name the required
mock pattern. `plugins/agent/intake/tests/intake-result-test.sh` is in scope.

**SPEC-8 scope expansion (no change needed).**
All four files from an earlier finding remain in scope.  `core/state/resume.sh:80`
and `core/output/stage-io.sh:637` are excluded from the `|| true` requirement;
`plugins/agent/build/lib/secrets.sh:172` and `plugins/tool/test/lib/own-checks.sh:72,96,101`
carry `|| true`. The >= 17 threshold is satisfied (18 in current worktree).

**Lint-disposition-words constraint (no change needed).**
The fallback comment block in `plugins/tool/test/plugin.sh` must not contain the
literal token `stage_result_add`. This is an implementation-only constraint
stated in the Decision section. The file is in scope.

**`scripts/lib/stage-result.sh` is not in scope.** Its `atomic_write` calls use
here-strings (`<<< "$json"`), not pipes; the lint does not apply.

**`core/pipeline/contract-validator.sh` is not in scope.** Line 304 already
carries `|| true`; covered correctly without a scope entry.

**`core/state/resume.sh` is the reference pattern.** Lines 80–91 are the correct
pattern and must not be changed. In scope only for the SPEC-8 test's non-vacuous
exclusion check.
