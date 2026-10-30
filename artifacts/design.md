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
reads and merges the stale data, producing a hybrid that neither reflects the
current run nor triggers the broken fallback. The fallback is only entered when
`_jq_rc != 0` — which a failed write never sets.

`_intake_run_inner` in `plugins/agent/intake/plugin.sh` writes `scope-manifest.md`
and `intake.md` with two bare `| atomic_write` calls and no exit check. Both
files are read by the plan stage on every iteration. A write failure leaves the
prior round's content in place while intake continues to report `pass`.

`core/state/resume.sh` already shows the correct pattern for this situation:
capture both `PIPESTATUS[0]` (jq's exit) and `PIPESTATUS[1]` (atomic_write's
exit) on a single `local` statement, before any other command resets PIPESTATUS,
then fail closed on either non-zero value.

**Decision.**
1. Fix `_test_write_result`: capture `PIPESTATUS[1]` on the same `local`
   declaration as `PIPESTATUS[0]`. Treat a non-zero write exit the same as a
   non-zero jq exit — trigger the existing broken fallback.
2. Fix `_intake_run_inner`: check each `atomic_write` exit; on failure call
   `_intake_write_result` with outcome `broken` and a reason naming the file,
   then return 1.
3. Add `scripts/lib/lint-atomic-write-unchecked.sh`: scan `.sh` files under
   `core/`, `plugins/`, and `scripts/` for `| atomic_write` whose exit is not
   handled on the same or immediately following physical line via `&&`, `||`,
   `if !`, or a PIPESTATUS capture that includes the write index. Emit a
   file-and-line message per violation and exit non-zero.
4. Wire the lint into `package.json`'s `lint` target.
5. Annotate every pre-existing unchecked `| atomic_write` site outside the two
   bugs with `|| true` (13 locations in 9 files). These write diagnostic or
   auxiliary data; `|| true` makes the best-effort intent explicit and lets the
   lint pass on the full codebase.

**Divergence from plan.** The plan's 7-item scope omits the 9 additional files
with unchecked `| atomic_write` calls. A broad lint rule flags them all; those
sites must carry `|| true` for `npm run lint` to pass. All 9 files are added to
scope.

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
```

```acceptance
SPEC-1[code]: when jq succeeds but atomic_write fails in _test_write_result, the broken fallback is written with outcome=broken and reason=result_write_failed covers: R-1
SPEC-2[code]: runner_read_stage_verdict classifies the result on disk after a primary-path atomic_write failure as broken, not as the prior round's outcome covers: R-1
SPEC-3[code]: _intake_run_inner writes a broken result whose reason names scope-manifest.md and returns non-zero when atomic_write for that file fails covers: R-1
SPEC-4[code]: _intake_run_inner writes a broken result whose reason names intake.md and returns non-zero when atomic_write for that file fails covers: R-1
SPEC-5[code]: scripts/lib/lint-atomic-write-unchecked.sh exits non-zero and names the violating line when given a .sh file containing a bare unchecked pipe to atomic_write covers: R-1
SPEC-6[code]: scripts/lib/lint-atomic-write-unchecked.sh exits 0 when every pipe to atomic_write in a .sh file is followed on the same or next physical line by &&, ||, if !, or PIPESTATUS that includes the write index covers: R-1
SPEC-7[code]: package.json lint target contains bash scripts/lib/lint-atomic-write-unchecked.sh covers: R-1
SPEC-8[no-code]: all 13 pre-existing unchecked | atomic_write calls in core/ plugins/ scripts/ outside the two bugs carry || true so scripts/lib/lint-atomic-write-unchecked.sh exits 0 on the full codebase covers: R-1
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

**Scope expansion (plan vs. design).** The plan lists 7 items across 8 files.
The broad lint rule adds 9 more files: `core/detect/platforms.sh`,
`core/pipeline/state_helpers.sh`, `core/output/destinations.sh`,
`plugins/agent/pr-delivery/plugin.sh`, `plugins/tool/merge/plugin.sh`,
`plugins/tool/output-github-comment/plugin.sh`, `plugins/tool/pr-open/plugin.sh`,
`plugins/tool/test/lib/acceptance-reason.sh`,
`plugins/tool/test/lib/acceptance-check.sh`. Each carries between 1 and 2
unchecked `| atomic_write` calls that would fail the lint. All write
diagnostic/auxiliary artifacts; `|| true` is the correct annotation. Not
addressing them would ship a lint that immediately fails CI.

**`core/state/resume.sh` is already correct.** Lines 80–91 pipe to `atomic_write`
and then capture both `PIPESTATUS[0]` and `PIPESTATUS[1]` on a single `local`
statement, failing closed on either. This is the reference pattern for the
test-plugin fix.

**`scripts/lib/stage-result.sh` is not in scope.** Its `atomic_write` calls use
here-strings (`<<< "$json"`), not pipes, so the `| atomic_write` lint does not
apply. The function's return value is atomic_write's exit code; callers that
invoke `stage_result_write` check it.

**SPEC-2 belongs in `test-result-reason-contract-test.sh`** because that file
already sources both the test plugin's writer and `runner_read_stage_verdict`.
The test requires a prior-round file to be present on disk before the write
failure, so the assertion is not just "fallback is written" but "the reader
sees broken and not the stale prior value."
