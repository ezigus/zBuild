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
