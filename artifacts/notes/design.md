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
