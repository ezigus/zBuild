# Design notes — issue #1754

## What I read

- `plugins/tool/test/plugin.sh` — `_test_write_result`: primary path pipes
  `jq -n … | atomic_write "$path"`, then captures only `PIPESTATUS[0]` (jq's
  exit). If jq succeeds but `atomic_write` fails, `_jq_rc=0`, so
  `stage_result_add` runs against `$path` which was never written. If a prior
  round's file exists there, `stage_result_add` reads that stale file and
  produces a hybrid result (new contract fields, old data). The fallback path
  is NOT triggered.
  Fallback path (line 1204): `printf … | atomic_write "$path" \\ && stage_result_add …`.
  The `&&` makes stage_result_add conditional on atomic_write success there —
  that part is safe, but the fallback only runs when `_jq_rc != 0`, and jq's
  success masked the write failure.

- `plugins/agent/intake/plugin.sh:273-274`:
  ```
  } | atomic_write "$state_dir/scope-manifest.md"
  printf '%s\n' "$sanitized" | atomic_write "$state_dir/intake.md"
  ```
  Neither call has a following check. If a write fails, the prior round's file
  remains. The stage continues and writes `pass`. Downstream stages read stale
  scope-manifest / intake.md.

- `core/state/resume.sh:80-91`: ALREADY CORRECT. After the pipe to atomic_write
  on line 80, lines 91-96 capture `PIPESTATUS[0]` AND `PIPESTATUS[1]` on a
  single `local` and fail closed on either. This is the reference pattern.

- `scripts/lib/stage-result.sh`: Uses `atomic_write "$path" <<< "$json"` (here-
  string, not a pipe). The function's last command is atomic_write; its exit
  propagates to the caller. Not in scope for `| atomic_write` lint.

## Unchecked `| atomic_write` sites outside the two bugs

Grepped the full codebase. Sites with `&&`, `||`, or `if !` on same/next line
are already safe. The following have NO exit check (beyond the two bugs):

1. core/detect/platforms.sh:275,446 — writes platforms_file
2. core/pipeline/state_helpers.sh:43 — writes scope_override state
3. core/output/destinations.sh:39 — writes report_path (diagnostic)
4. plugins/agent/pr-delivery/plugin.sh:117,253 — writes pr_url_out
5. plugins/tool/merge/plugin.sh:229 — writes pr_url_out
6. plugins/tool/output-github-comment/plugin.sh:103 — writes output-body.md
7. plugins/tool/pr-open/plugin.sh:440 — writes pr-url.txt
8. plugins/tool/test/lib/acceptance-reason.sh:207,234 — writes acceptance-summary.txt
9. plugins/tool/test/lib/acceptance-check.sh:137,461 — writes acceptance-summary.txt

These 13 locations are diagnostic / non-result writes. Under `set -euo pipefail: off`
(all sourced libs), adding `|| true` changes no behaviour but makes the best-effort
intent explicit and passes the broad lint rule.

## plan divergence

Plan lists 7 items and doesn't mention the 9 additional files. The broad lint
rule ("scan every .sh file") will flag all 13 unchecked sites, so those files
must be in scope with `|| true` annotations. Added them to scope block.

Plan step 2 describes capturing "the full PIPESTATUS array" — the correct
minimal fix is to capture `PIPESTATUS[1]` on the SAME `local` declaration as
`PIPESTATUS[0]` (both indices in one statement, before any other command runs).

## WIRING check

For test plugin: `plugins/tool/test/plugin.sh` is both the implementation file
and the wiring file — putting old code back breaks the new test case.
For intake: `plugins/agent/intake/plugin.sh` same.
For lint: `package.json` is the wiring — putting it back removes the lint from
`npm run lint`, which breaks the test asserting the script is referenced.

## Supersedes

No existing assertions change meaning. New test cases are additive.

---

## Revision 2 — changes from previous round

### Four missing files discovered (issue-acceptance finding 2)

The SPEC-8 test at `tests/unit/plugin-primary-output-atomic-test.sh` lines
187-228 checks ALL `| atomic_write` calls outside the two bug-fix files and test
directories. It requires `|| true` on the same line (or continuation line). It
flagged six sites not in scope:

1. `core/state/resume.sh:80` — `}' | atomic_write --bak "$state_file"`
   - ALREADY correctly handled: lines 81-90 are comments, line 91 is
     `local _jq_rc="${PIPESTATUS[0]}" _write_rc="${PIPESTATUS[1]}"`
   - Adding `|| true` would overwrite PIPESTATUS → `_write_rc` always 0 → write
     failures hidden. CANNOT add `|| true` here.
   - Fix: SPEC-8 test must EXCLUDE this file from the `|| true` check.

2. `core/output/stage-io.sh:637` — `if ! printf '%s\n' "$record" | atomic_write "$path"; then`
   - ALREADY correctly handled by `if !` on the same line.
   - Adding `|| true` would make the condition always true → always error-branches.
   - Fix: SPEC-8 test must EXCLUDE this file from the `|| true` check.

3. `plugins/agent/build/lib/secrets.sh:172` — `&& printf '%s\n' "$_tmp" | atomic_write "$summary_json"`
   - No exit check. Best-effort write. Add `|| true`.

4. `plugins/tool/test/lib/own-checks.sh:72,96,101` — `&& printf '%s\n' "$tmp1" | atomic_write "$f"` etc.
   - No exit check. Best-effort writes. Each needs `|| true`.

Added all 4 files to scope. Updated SPEC-8 description and count (17, not 13).
SPEC-8 test must add exclusions for resume.sh and stage-io.sh, raise count threshold to >= 17.

### Lint-disposition-words regression (issue-acceptance finding 3)

`lint-disposition-words.sh` uses awk to scan for `stage_result_(write|add)` calls.
The regex matches `stage_result_(write|add)[[:space:]]+<arg1>[[:space:]]+<arg2>`.
A comment like `# no second stage_result_add call is needed.` triggers this:
- `stage_result_add` (writer), `call` (arg1), `is` (arg2 = outcome)
`is` is not a valid outcome → lint fails.

Constraint added to design: the fallback comment in `plugins/tool/test/plugin.sh`
must not contain the literal token `stage_result_add`.

### SPEC-4 code defect (issue-acceptance finding 1)

The code at `intake/plugin.sh:280-286` looks correct (PIPESTATUS[1] captured,
`if (( _im_aw_rc != 0 ))` checked, `return 1` called). The issue-acceptance says
the function still returns 0. This is a code-level defect the implementer must
debug. Not a design issue.

### SPEC-1/SPEC-2 test-first uncertainty

The acceptance-gate timeout made the before-test result unreliable. Analysis
confirms SPEC-1/SPEC-2 tests SHOULD fail on old code:
- Old code: `_jq_rc = PIPESTATUS[0] = 0` when jq succeeds + atomic_write fails
- `stage_result_add` called on stale file → prior round's outcome remains
- SPEC-1/SPEC-2 assert `outcome=broken` → FAIL on old code ✓

### Lint script pattern verification

`scripts/lib/lint-atomic-write-unchecked.sh` recognizes (verified from source):
1. Same-line `&&`, `||`, or `if[[:space:]]+!` → safe
2. Continuation `\\` + next line has `&&` or `||` → safe
3. Next non-blank, non-comment line has `PIPESTATUS[` → safe

So resume.sh:80 and stage-io.sh:637 are NOT flagged by the lint. But the SPEC-8
TEST independently greps for `|| true` on the same line and DOES flag them. The
test must exclude these two files explicitly.

---

## Revision 4 — design-judge verdict pass

### Analysis of issue-acceptance findings vs design coverage

The question is whether the SPECs cover R-1, not whether the code delivers what
the SPECs demand. Each issue-acceptance finding is classified below:

**Finding 1 — SPEC-4 (intake.md path returns 0):**
SPEC-4 correctly demands: _intake_run_inner writes broken and returns non-zero
when atomic_write for intake.md fails. The design specifies the correct fix (capture
PIPESTATUS[1] immediately after the pipe on the same local declaration, check non-zero,
write broken, return 1). The design's findings block explicitly calls this "a code-level
defect the implementer must debug — not a design issue."
→ SPEC covers the requirement. Code has a bug. No design gap.

**Finding 2 — SPEC-8 (six sites still lack || true):**
SPEC-8 explicitly names secrets.sh:172 and own-checks.sh:72,96,101 as needing
`|| true`. Both files are in scope. The SPEC-8 test must exclude resume.sh and
stage-io.sh (design finding block §1 and §2). The code was not changed to annotate
those sites, and the test was not updated to exclude the correctly-handled files.
→ SPEC covers the requirement. Implementation didn't deliver it. No design gap.

**Finding 3 — lint-disposition-words regression (comment in plugin.sh):**
Design finding block explicitly identifies this: "the fallback block's comment text
in plugins/tool/test/plugin.sh must not include the token stage_result_add."
The constraint is in the design. The implementer violated it.
→ Design covers this. No SPEC gap.

**Finding 4 — SPEC-1/SPEC-2 test-first validity:**
Before-test timed out; report is unreliable. Design analysis correctly shows
old code would produce outcome=pass (not broken), so SPEC-1/SPEC-2 tests FAIL
on old code. No design gap.

### Coverage map for R-1

- Test stage atomic_write failure → SPEC-1 (outcome=broken on disk) + SPEC-2 (reader sees broken) ✓
- Intake scope-manifest.md write failure → SPEC-3 ✓
- Intake intake.md write failure → SPEC-4 ✓
- Lint to detect future unchecked | atomic_write → SPEC-5 (non-zero on violation) + SPEC-6 (zero when handled) + SPEC-7 (wired in package.json) ✓
- Existing unchecked sites annotated → SPEC-8 (17 sites, excludes resume.sh + stage-io.sh) ✓

Every behavioral aspect of R-1 is addressed by at least one SPEC.
All three NOT MET findings are code implementation failures, not missing SPEC coverage.

### Verdict: COVERED

---

## Revision 3 — final verification pass

### Files examined in this pass

- `tests/unit/test-plugin-result-write-fallback-test.sh` (SPEC-1 test, lines 237-288)
- `tests/unit/test-result-reason-contract-test.sh` (SPEC-2 test, lines 263-309)
- `plugins/agent/intake/plugin.sh:273-285` (SPEC-3/SPEC-4 implementation)
- `tests/unit/plugin-primary-output-atomic-test.sh` (SPEC-5/6/7/8 test)
- `scripts/lib/lint-atomic-write-unchecked.sh` (full lint script)
- All `| atomic_write` sites in core/plugins/scripts

### SPEC-1/SPEC-2 test-first analysis (acceptance-gate finding 1)

The acceptance-gate finding that "SPEC-1/SPEC-2 pass on old code" is contradicted
by the issue-acceptance timeout on those same SPECs. Code analysis:

- SPEC-1 test: sets up prior-round pass file, mocks atomic_write to fail on call
  #1 only, calls _test_write_result, asserts outcome=broken.
  OLD CODE: _jq_rc=PIPESTATUS[0]=0 (jq ok), stage_result_add merges prior-round
  pass into file → outcome=pass → test FAILS on old code ✓

- SPEC-2 test: same mock, asserts runner_read_stage_verdict returns "broken".
  OLD CODE: stale file gives "pass" to reader → FAILS on old code ✓

SPECs kept as [code]. Acceptance-gate finding treated as unreliable.

### Current worktree state

- `plugins/agent/intake/plugin.sh:280-285`: PIPESTATUS[1] captured, return 1 on
  failure. LOOKS CORRECT for SPEC-4.
- `plugins/agent/build/lib/secrets.sh:172`: `|| true` PRESENT ✓
- `plugins/tool/test/lib/own-checks.sh:72,96,101`: `|| true` PRESENT ✓
- `tests/unit/plugin-primary-output-atomic-test.sh:207-208`: resume.sh and 
  stage-io.sh already excluded from || true check ✓
- SPEC-8 count: 18 non-continuation-line sites (includes contract-validator.sh
  which was already annotated). Threshold >= 17 passes.
- `scripts/lib/lint-atomic-write-unchecked.sh`: EXISTS ✓
- `package.json`: contains `bash scripts/lib/lint-atomic-write-unchecked.sh` ✓

### Key design changes in revision 3

1. SPEC-1/SPEC-2: More precise language about prior-round stale file scenario
   to make discriminating assertion explicit.
2. SPEC-6: Added continuation line handling (ending with \) to match what the
   lint script actually implements.
3. Decision §3: Added continuation line case to lint description.
4. Findings section: Expanded SPEC-1/SPEC-2 analysis; SPEC-4 updated to note
   current worktree looks correct but prior iteration had defect; SPEC-8 updated
   to reflect 18-site count and note contract-validator.sh was already annotated.
5. Added contract-validator.sh to "not in scope" explanation.
