# Plan checkpoint — issue #1932

## Files read and key findings

- `core/state/issue-lock.sh`: per-issue keyed mutex; `zbuild_issue_lock_acquire/release`; state root `${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/locks`; uses `zbuild_run_is_live` from resume.sh; contains the "NOT A CAPACITY CAP" comment confirming the gap.
- `core/state/resume.sh`: `zbuild_run_is_live(state_file)` — rc=0 if status=in_progress AND updated_at <24h old.
- `core/state/layout.sh`: `zbuild_layout_state_root()` returns `${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}`.
- `core/pipeline/runner.sh`: sources issue-lock.sh at line ~26; acquires issue lock at ~2302; release in exit trap at ~2470.
- `tests/unit/issue-lock-test.sh`: model for unit tests — subprocess pattern for true concurrency tests.
- `docs/adr/ADR-059-issue-vs-run-keying.md`: §4 is the existing mutex; §5=goal keying, §6=identity derivation. `## Enforced by` section names 3 test files. Issue requires amending ADR-059 with a new §7 cap section + Enforced by entry.

## Plan

1. Create `core/state/run-cap.sh` — cap module
2. Modify `core/pipeline/runner.sh` — integrate cap check + release in exit trap
3. Create `tests/unit/run-cap-test.sh` — 5 spec tests per issue scope
4. Amend `docs/adr/ADR-059-issue-vs-run-keying.md` — §7 + Enforced by

## Key design decisions
- Slot dir: `${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/run-slots`
- Slot file: `$$.json` (PID-keyed), contains run_id, pid, state_file, acquired_at
- Admission: reap stale → count live (excluding own PID $$ since slot not yet written) → if count >= cap refuse → else write slot
- Fail-open: any error in reap/count warns and admits
- `ZBUILD_MAX_CONCURRENT_RUNS` unset = no cap (entire function returns 0 immediately)
- `ZBUILD_NO_RUN_CAP=1` = override, admitted with warning
- Release: remove `<slot_dir>/$$.json` in exit trap alongside issue lock release

## Still unresolved
- Race window: two runs starting simultaneously may both count 0 others and both write slots, exceeding the cap. Same limitation as issue-lock's no-flock fallback; to be stated in the ADR (not hidden).
