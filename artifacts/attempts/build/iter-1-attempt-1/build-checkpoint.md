# Build Checkpoint — issue #1932

## Files read and what they told me

- `tests/unit/run-cap-test.sh` — acceptance tests: 7 SPECs testing zbuild_run_cap_admit behavior, ADR-059 §7, and event-schema.json. Key: SPEC-1 captures both stdout+stderr with `2>&1`, so no-output means truly silent. SPEC-5 tests chmod 000 on ZBUILD_STATE_ROOT itself (not run-slots), so mkdir -p will fail. SPEC-2/_ZBUILD_RUN_CAP_BLOCKERS must be set in the calling shell (not a subshell). _cap_admit_subprocess uses bash -c subshell so slots persist after exit.
- `core/state/issue-lock.sh` — structural model for run-cap.sh: guard pattern, source resume.sh, fail-open mkdir, reap-before-count, opt-out env var, explicit release.
- `core/state/resume.sh` — zbuild_run_is_live at line 217: rc=0 if status=in_progress AND updated_at < 24h.
- `docs/adr/ADR-059-issue-vs-run-keying.md` — needs §7 "Host-wide run cap, off unless configured" under Decision and Enforced-by bullet.
- `config/event-schema.json` — needs "pipeline.refused.run_cap" added to known_types array.
- `core/pipeline/runner.sh` — source issue-lock.sh at line 25-26 (need to add run-cap.sh there); zbuild_issue_lock_acquire call at ~2302 (add zbuild_run_cap_admit BEFORE it); _runner_abort_trap at 2461 with zbuild_issue_lock_release at 2470 (add zbuild_run_cap_release there).

## Conclusions

- run-cap.sh must NOT be called in a subshell for admit, because _ZBUILD_RUN_CAP_BLOCKERS must survive in the calling shell.
- Slot file format: JSON with run_id, pid, state_file, acquired_at.
- zbuild_run_cap_reap_stale: for each slot, read state_file via jq, call zbuild_run_is_live; if not live, rm -f.
- SPEC-5: mkdir -p on slot_dir (which is under chmod 000 ZBUILD_STATE_ROOT) fails → warn >&2 + return 0.
- Count must exclude own PID's slot file (named $$.json).

## What I'm doing now

1. Create core/state/run-cap.sh
2. Modify core/pipeline/runner.sh (3 sites)
3. Amend docs/adr/ADR-059-issue-vs-run-keying.md (§7 + Enforced-by)
4. Add pipeline.refused.run_cap to config/event-schema.json
