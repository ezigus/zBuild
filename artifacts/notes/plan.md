# Plan notes — issue #1754

## What I read

- `plugins/tool/test/plugin.sh` lines 1142–1207: `_test_write_result`
  - pipes `jq … | atomic_write "$path"` then captures `PIPESTATUS[0]` (jq's rc, not the write's)
  - `PIPESTATUS[1]` (atomic_write rc) is never examined
  - When `atomic_write` fails but jq succeeds, `_jq_rc==0`, so `stage_result_add` runs against the old file, tagging the old round's counts as current
  - The fallback path (`printf '…' | atomic_write "$path" && stage_result_add`) is already correct (uses `&&`)

- `plugins/agent/intake/plugin.sh` lines 262–274: `_intake_run_inner`
  - two bare writes: `} | atomic_write "$state_dir/scope-manifest.md"` and `printf '%s\n' "$sanitized" | atomic_write "$state_dir/intake.md"`
  - neither checks the exit status of `atomic_write`; function continues and returns 0

- Existing test files already loaded in scope:
  - `test-plugin-result-write-fallback-test.sh`: already tests jq failure → broken (section 8); NEW test needed for atomic_write failure (jq ok, write fails) with a prior round file present
  - `test-result-reason-contract-test.sh`: already tests reader path; NEW SPEC needed to confirm the reader sees `broken` not the prior round's data when the write fails
  - `plugin-primary-output-atomic-test.sh`: static grep check for primary outputs; NEW section needed for the lint-script test
  - `intake-result-test.sh`: covers v2 result contract; NEW test section for write-failure on both scope-manifest.md and intake.md

- `package.json` lint target: long chain of `&&` calls; new lint script appended at the end

## Key decisions

- R1 fix: capture `PIPESTATUS` as an array immediately after the pipe; check index 1 (write) as well as index 0 (jq); trigger the broken fallback when either fails
- R2 fix: after each `| atomic_write` call, add `|| { error "intake: failed to write $state_dir/<file>"; _intake_write_result … broken "write failed: <file>"; return 1; }`
- R3 lint: a new `scripts/lib/lint-atomic-write-unchecked.sh` that greps for `| atomic_write` in `core/`, `plugins/`, `scripts/` and checks the line (and the line immediately after, for `PIPESTATUS` on the next line) for a checked exit

## Open questions

None — issue is fully specified.

## Step count: 7
