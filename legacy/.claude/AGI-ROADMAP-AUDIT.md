# AGI Roadmap Implementation — Audit & Gaps

## Bugs fixed during audit

1. **sw-testgen.sh — Claude prompt omitted function body**  
   The prompt sent to Claude only said "Function: ${func}." and did not include `func_snippet`, so generated tests had no real behavior to assert. **Fixed:** Build prompt in a temp file and include the function body so Claude can generate meaningful tests.

2. **sw-feedback.sh — Rollback exit code ignored**  
   `if bash ... 2>&1 | tee -a file; then` uses the exit code of `tee`, not the rollback script, so rollback failures were reported as success. **Fixed:** Capture `PIPESTATUS[0]` after the pipeline and use it to set `rollback_status` and warnings.

---

## What we did not test or validate

### No new or updated unit/integration tests

- **Failure learning:** No test that `failure_history` is appended, that `get_max_retries_for_class` returns expected values, or that pause file gets `resume_after`.
- **PM integration:** No test that daemon calls `pm recommend --json` and uses `.team_composition.template`, or that `pm learn` is called on success/failure.
- **Feedback:** No test that `feedback rollback` invokes `sw-github-deploy.sh rollback` or that pipeline monitor calls `feedback collect` / `create-issue`.
- **Predictive:** No test that pipeline calls `predict_detect_anomaly` / `predict_update_baseline` / `inject-prevention`.
- **Oversight gate:** No test that `oversight gate --reject-if "reason"` returns rejected and that pipeline blocks on it.
- **Autonomous:** No test that `create_issue_from_finding` echoes issue number, that pipeline is triggered, or that `update_finding_outcomes` updates pending_findings.
- **Incident:** No test that P0/P1 triggers pipeline and that `auto_rollback_enabled` calls feedback rollback.
- **Code review:** No test that Claude semantic review runs and that findings are merged into the report.
- **Testgen:** No test that Claude path generates assertions or that function body is in the prompt.
- **Swarm:** No test that spawn creates a tmux session or that retire kills it.
- **Stage effectiveness / self-awareness:** No test that `stage-effectiveness.jsonl` is written or that plan hint is injected.

**Recommendation:** Add or extend tests in the existing `sw-*-test.sh` scripts (e.g. `sw-daemon-test.sh`, `sw-feedback-test.sh`, `sw-oversight-test.sh`, `sw-autonomous-test.sh`, etc.) with mocks for external commands and file/state assertions.

### integration-claude job not exercised without secrets

- The `integration-claude` workflow job runs only when `secrets.CLAUDE_CODE_OAUTH_TOKEN` or `secrets.ANTHROPIC_API_KEY` is set.
- The “skip when no secret” path of `sw-integration-claude-test.sh` is never run in CI, so we do not validate that it exits 0 and skips cleanly when unset.

**Recommendation:** In `test.yml`, add a step that runs `scripts/sw-integration-claude-test.sh` without secrets and asserts exit 0 and “Skipping integration-claude” (or similar) in output.

---

## What we did not audit or prove

### End-to-end flows

- No run of a full pipeline with discovery + predictive + oversight gate + feedback monitor.
- No run of daemon with PM + failure learning + pause/resume.
- No run of autonomous `cycle` or `run` with real GitHub (would create issues and trigger pipelines).
- No run of incident watch with P0/P1 and auto-rollback + pipeline trigger.

So we have not proven that the new wiring works together in a real environment.

### Cross-platform and environment

- **Pause `resume_after`:** Daemon uses `date -j -f ...` (macOS) and `date -d ...` (Linux). Not verified on both.
- **timeout:** integration-claude and testgen use `timeout` when available; behavior when missing (e.g. some macOS) is “run without timeout,” which is acceptable but not explicitly tested.
- **bc:** Oversight and other scripts may use `bc` for arithmetic; not confirmed to be present everywhere.

### State and backward compatibility

- **Existing daemon state:** Old `daemon-state.json` files do not have `failure_history`. The code uses `// []` in jq, so the first append is safe. Not tested against a real pre-upgrade state file.
- **Existing oversight:** No migration for older review files or config; assumed compatible.
- **PM history:** `recommend --json` still appends to PM history; no test that history format remains valid.

### Security and robustness

- **Feedback rollback:** Runs `sw-github-deploy.sh rollback production`; no check that `environment` is sanitized (e.g. if it were `production; rm -rf /`). Low risk if only called from our code with fixed args.
- **Pipeline / daemon:** No audit of whether new code paths can be made to run arbitrary commands via env or crafted inputs.
- **ARTIFACTS_DIR / REPO_DIR:** Several scripts assume these are set; when invoked from pipeline/daemon they are, but ad-hoc calls might not set them (fallbacks exist in some scripts, not all).

---

## Possible follow-ups

1. **Tests:** Add targeted tests (with mocks) for each new integration point in the corresponding `sw-*-test.sh` files.
2. **CI:** Add a job or step that runs `sw-integration-claude-test.sh` without secrets and checks for “skip” behavior.
3. **Playbook / cross-run:** Daemon could record (template, outcome) per issue and use it to suggest template for similar issues; only confidence-based upgrade was implemented.
4. **Multi-agent restarts:** We allowed `--max-restarts` in multi-agent mode but did not add logic to actually restart an agent or the team; the flag is now passed through only.
5. **Pending findings growth:** `pending_findings.jsonl` in autonomous never prunes resolved entries; consider keeping only pending or last N.
6. **Stage effectiveness pruning:** `stage-effectiveness.jsonl` is trimmed to last 100 lines; no test that trimming works under load.

---

## Summary

| Area             | Status                                                              |
| ---------------- | ------------------------------------------------------------------- |
| Critical bugs    | 2 found and fixed (testgen prompt, feedback rollback exit code).    |
| Unit/integration | No new tests added for new behavior.                                |
| E2E / live proof | No full pipeline or daemon run with new features.                   |
| Cross-platform   | Pause date parsing and timeout usage not verified on all platforms. |
| Backward compat  | State without `failure_history` handled in jq; not tested.          |
| Security         | No formal review; rollback args are controlled by our code.         |

Implementations match the intended design, but **validation is mostly by code review, not by automated or E2E tests**. Adding the recommended tests and one CI step for the integration-claude skip path would significantly improve confidence.
