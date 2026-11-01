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
  - `plugin-primary-output-atomic-test.sh`: static grep check for primary outputs; NEW section needed for the lint-script test (including SPEC-8: lint passes on full codebase)
  - `intake-result-test.sh`: covers v2 result contract; NEW test section for write-failure on both scope-manifest.md and intake.md

- `package.json` lint target: long chain of `&&` calls; new lint script appended at the end

- Design stage findings (updated from initial notes):
  - 11 files (not 9) with unchecked `| atomic_write` calls that need `|| true`:
    - core/detect/platforms.sh
    - core/pipeline/state_helpers.sh
    - core/output/destinations.sh
    - plugins/agent/pr-delivery/plugin.sh
    - plugins/tool/merge/plugin.sh
    - plugins/tool/output-github-comment/plugin.sh
    - plugins/tool/pr-open/plugin.sh
    - plugins/tool/test/lib/acceptance-reason.sh
    - plugins/tool/test/lib/acceptance-check.sh
    - plugins/agent/build/lib/secrets.sh (NEW — was missing from initial plan)
    - plugins/tool/test/lib/own-checks.sh (NEW — was missing from initial plan)
  - Total 17 unchecked sites (not 13) → SPEC-8 count threshold is ≥17
  - Two files already correctly handled — must NOT get `|| true`:
    - `core/state/resume.sh:80` — PIPESTATUS[1] captured on subsequent local statement; `|| true` would hide write failures
    - `core/output/stage-io.sh:637` — `if ! … | atomic_write …` pattern; `|| true` would always trigger the error branch

- Design also added constraint: the `_test_write_result` fallback block must NOT use the literal token `stage_result_add` in any comment — lint-disposition-words scans comments too.

## Key decisions

- R1 fix: capture `PIPESTATUS` as an array immediately after the pipe on a single `local` declaration; check index 1 (write) as well as index 0 (jq); trigger the broken fallback when either fails; no comment containing `stage_result_add` in the fallback block
- R2 fix: after each `| atomic_write` call, capture PIPESTATUS[1]; on failure call `_intake_write_result` with outcome `broken` and a reason naming the file; return non-zero ensuring no later code overwrites result to `pass`
- R3 lint: a new `scripts/lib/lint-atomic-write-unchecked.sh` that greps for `| atomic_write` in `core/`, `plugins/`, `scripts/` and checks the same line and next non-blank non-comment line for checked exit
- Pre-existing safe uses: annotate 17 sites across 11 files with `|| true`; SPEC-8 test excludes `core/state/resume.sh` and `core/output/stage-io.sh`

## Open questions

None — issue is fully specified.

## Step count: 8 (design expanded scope: 2 more files, 4 more sites; SPEC-8 threshold updated to ≥17)

## Design findings incorporated into plan update

**SPEC-4 mock bug (design finding 2):** Step 3 updated to specify the correct mock pattern.
The original plan said "a targeted mock that lets scope-manifest.md succeed" without naming
the broken exclusion pattern. The design found that `*"intake.md" && != *"intake-result"*`
silently passes because the temp dir `plugin-intake-result.XXXXXX` contains "intake-result"
as a substring, making the mock never fire. Step 3 now specifies `"${_aw_target##*/}" == "intake.md"`.

**SPEC-1/SPEC-2 diff completeness (design finding 1):** No plan change needed. The tests are
correctly discriminating. The implementer must include `plugins/tool/test/plugin.sh` in the
submitted diff — it is already in WIRING and step-2's areas.
