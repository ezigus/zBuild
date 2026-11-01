# Design — #1754: Fix unchecked atomic_write exits in test plugin and intake

## Architectural decision summary

**Goal.** A failed `atomic_write` on the result-write path of the test stage or
intake must never silently leave a prior round's file looking current. A
structural lint rule prevents the same class of defect from reappearing.

**Context.**
`_test_write_result` in `plugins/tool/test/plugin.sh` already had
`local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"` before this issue,
so the primary write's exit is captured. The actual bug was in the **fallback
block**: when primary atomic_write fails, the fallback used
`printf … | atomic_write "$path" && stage_result_add "$path" broken
"result_write_failed"`. If a test mock intercepts ALL atomic_write calls, the
fallback `| atomic_write` also fails → `&&` short-circuits → stage_result_add
is never called → the broken result is never written → the prior-round file
(e.g. "pass") remains — and no indication of the write failure appears.

`_intake_run_inner` in `plugins/agent/intake/plugin.sh` had
`printf "DEBUG_PIPE PIPESTATUS_BEFORE_LOCAL=(%s)\n" "${PIPESTATUS[*]:-}" >>
/tmp/intake_debug.txt` inserted between
`printf '%s\n' "$sanitized" | atomic_write "$state_dir/intake.md"` and
`local _im_aw_rc="${PIPESTATUS[1]}"`. That printf resets PIPESTATUS, so
`_im_aw_rc` was always 0 regardless of whether `atomic_write` failed. The
scope-manifest write had no such debug line and was already correct.

`core/state/resume.sh` shows the correct pattern: capture both PIPESTATUS
indices on a single `local` statement immediately after the pipe, with no
intervening command that could reset PIPESTATUS.

**Decision.**
1. Fix `_test_write_result` fallback block: replace
   `printf … | atomic_write "$path" && stage_result_add "$path" broken
   "result_write_failed"` with `printf … > "$path" 2>/dev/null || true`.
   The JSON must include `result_contract`, `outcome`, and `reason` inline
   (no second stage_result_add needed). Using a direct redirect makes the
   fallback immune to any test mock on `atomic_write`. The fallback comment
   block must NOT contain the literal token `stage_result_add` (the
   `lint-disposition-words` awk scanner matches that token in comments as if it
   were a live writer call).
2. Fix `_intake_run_inner`: remove the debug `printf` lines that reset
   PIPESTATUS between the intake.md pipe and `local _im_aw_rc="${PIPESTATUS[1]}"`;
   on failure call `_intake_write_result` with outcome `broken` and a reason
   naming the file, then `return 1`.
3. Add `scripts/lib/lint-atomic-write-unchecked.sh`: scan `.sh` files under
   `core/`, `plugins/`, and `scripts/` for `| atomic_write` whose exit is not
   handled. "Handled" means: `&&`, `||`, or `if !` on the same line; OR a shell
   continuation line (ending with `\`) whose immediately following physical line
   contains `||` or `&&`; OR a PIPESTATUS capture (`PIPESTATUS[`) on the next
   non-blank, non-comment executable line. Emit file:line per violation and exit
   non-zero.
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
SPEC-1[code]: when ALL atomic_write calls in _test_write_result are intercepted and fail — both the primary call and any pipe-based fallback call — with a prior-round pass result already at that path, the result file carries outcome=broken and reason=result_write_failed; the test mock must fail EVERY atomic_write call so only the direct-redirect fallback path (using > not | atomic_write) can write a result; on old code the fallback | atomic_write also gets intercepted → && short-circuits → stage_result_add not called → prior-round pass survives → assertion fails covers: R-1
SPEC-2[code]: after ALL atomic_write calls in _test_write_result are intercepted — same all-fail mock as SPEC-1 — with a prior-round pass result at the path, runner_read_stage_disposition returns broken (not complete); on old code the fallback fails to write → prior-round pass survives → disposition is complete, not broken covers: R-1
SPEC-3[done]: _intake_run_inner writes a broken result whose reason names scope-manifest.md and returns non-zero when atomic_write for that file fails covers: R-1 evidence: plugins/agent/intake/plugin.sh:273 plugins/agent/intake/plugin.sh:274
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
SPEC-4: plugins/agent/intake/tests/intake-result-test.sh
SPEC-5: tests/unit/plugin-primary-output-atomic-test.sh
SPEC-6: tests/unit/plugin-primary-output-atomic-test.sh
SPEC-7: tests/unit/plugin-primary-output-atomic-test.sh
SPEC-8: tests/unit/plugin-primary-output-atomic-test.sh
```

## Findings

**SPEC-1 and SPEC-2 — corrected from [done] to [code] (revision 7).**

Reading the pre-issue state of `plugins/tool/test/plugin.sh` (`git show 64960f4b^`)
revealed that `local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"` was
already present before this issue opened. The PIPESTATUS[1] capture for the
primary write was pre-existing, not a new addition. The actual bug was in the
**fallback block**:

Pre-issue fallback (broken):
```bash
printf '...' | atomic_write "$path" \
    && stage_result_add "$path" broken "result_write_failed"
```

New fallback (fixed):
```bash
printf '...' > "$path" 2>/dev/null || true
```

The pre-issue fallback uses `| atomic_write` which any test mock can intercept.
If a mock intercepts ALL atomic_write calls, the fallback `| atomic_write` (call
#2) also fails → `&&` short-circuits → `stage_result_add` is never called → no
broken result written → prior-round "pass" survives.

The current SPEC-1 and SPEC-2 test mocks use a **call-#1-only** pattern: they
only intercept the first atomic_write call, letting call #2 (the fallback) go
through. So the old fallback's `| atomic_write` call #2 succeeds, `stage_result_add`
is called, and outcome=broken is written even on old code. Both tests pass on old
code → the acceptance gate correctly flagged that no test catches the change.

**Fix:** Both SPEC-1 and SPEC-2 tests must use an **all-fail** mock that
intercepts every atomic_write call. This makes old code fail (fallback's
`| atomic_write` is intercepted → `&&` skips → no broken written → prior-round
"pass" survives) while new code passes (fallback's `> "$path"` bypass → broken
written). The test-author stage must update the mocks in both test files.

**SPEC-3 — corrected from [code] to [done] (revision 7).**

Reading the pre-issue intake plugin shows the scope-manifest PIPESTATUS[1] check
was already correct before this issue:
```bash
    } | atomic_write "$state_dir/scope-manifest.md"
    local _sm_aw_rc="${PIPESTATUS[1]}"
    if (( _sm_aw_rc != 0 )); then
        _intake_write_result "$_art" "broken" \
            "failed to write scope-manifest.md" || true
        return 1
    fi
```

No debug line was inserted between the pipe and the `local` statement. The
SPEC-3 test would pass on old code too. SPEC-3 is [done] with evidence at
`plugins/agent/intake/plugin.sh:273-274`. The existing [#1754/SPEC-3] assertions
in `intake-result-test.sh` remain as regression protection but no new test is
required.

**SPEC-4 — remains [code] (confirmed by revision 7 audit).**

The pre-issue intake.md PIPESTATUS capture was genuinely broken. A debug printf
was inserted between the pipe and `local _im_aw_rc="${PIPESTATUS[1]}"`:
```bash
printf '%s\n' "$sanitized"   | atomic_write "$state_dir/intake.md"
printf "DEBUG_PIPE PIPESTATUS_BEFORE_LOCAL=(%s)\n" "${PIPESTATUS[*]:-}" >> /tmp/intake_debug.txt
local _im_aw_rc="${PIPESTATUS[1]}"
```
The `printf … >> /tmp/…` command resets PIPESTATUS, so `_im_aw_rc` was always 0.
The fix removes those debug lines. The SPEC-4 test mock also had a bug (using
`*"intake.md" && != *"intake-result"*` which excluded paths containing the test
temp dir prefix "plugin-intake-result"); commit `6f9399a2` fixed it to use
`${_aw_target##*/}` == "intake.md". The code stage must include both the plugin
fix (lines 273-286 with no debug lines) and the corrected mock in the diff.

**WIRING: `plugins/tool/test/plugin.sh` added (revision 7).**
With SPEC-1/SPEC-2 as [code] and the fallback fix in that file, reverting
`plugins/tool/test/plugin.sh` should restore the `| atomic_write &&
stage_result_add` fallback; with the all-fail mock that tests now use, SPEC-1
and SPEC-2 assertions fail.

**SPEC-8 scope expansion (no change needed).**
All four files remain. `core/state/resume.sh:80` and `core/output/stage-io.sh:637`
are excluded from the `|| true` requirement; `plugins/agent/build/lib/secrets.sh:172`
and `plugins/tool/test/lib/own-checks.sh:72,96,101` carry `|| true`.

**Lint-disposition-words constraint (no change needed).**
The fallback comment block in `plugins/tool/test/plugin.sh` must not contain the
literal token `stage_result_add`. The current worktree already satisfies this.

**`scripts/lib/stage-result.sh` is not in scope.** Its `atomic_write` calls use
here-strings (`<<< "$json"`), not pipes; the lint does not apply.

**`core/pipeline/contract-validator.sh` is not in scope.** Line 304 already
carries `|| true`.

**`core/state/resume.sh` is the reference pattern.** Lines 80–91 are the correct
pattern and must not be changed. In scope only for the SPEC-8 test's non-vacuous
exclusion check.
