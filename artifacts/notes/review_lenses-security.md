# Security review — issue #1944 (run-level wall-clock watchdog)

## Files examined
- scripts/lib/stage-limits.sh: _runner_resolve_run_limit_s() new function
- core/pipeline/template.sh: template_max_run_s() new function
- core/pipeline/runner.sh: watchdog armed in main(), abort-trap changes, signal-trap change
- core/state/resume.sh: timed_out case added to get_resume_recommendation
- scripts/lib/abort-propagation.sh: timed_out word added

## Trust boundary analysis

### CLI boundary
`ZBUILD_MAX_RUN_S` accepted as operator input; validated regex `^[0-9]+$` + `-gt 0`
check before use. Template `max_run_s:` validated the same way. Both validated before
any stage dispatch. Solid.

### Template YAML parser (template_max_run_s)
awk pattern `/^max_run_s:[[:space:]]/` reads from `_TPL_SOURCE_FILE`. Output is
validated as integer. YAML injection cannot produce arbitrary shell execution here.
However `_TPL_SOURCE_FILE` is accepted without path-confinement check — relies on
template loader to have validated it. All sibling functions (`template_stage_negctl_timeout`
etc.) follow the same pattern, so this is pre-existing structural posture, not new risk
from this change. The integer-only output validation means file content can't exfiltrate
data even if path traversal in the loader existed.

### Watchdog PGID acquisition
`ps -o pgid= -p $$` — `$$` is the runner's own PID, always trusted.
`tr -d ' '` removes spaces; `$()` strips trailing newlines. Result is clean digits.
Fallback `$$` is also numeric. _RUNNER_RUN_PGID flows to `kill -TERM -- "-${_wdg_pgid}"`.
No explicit `^[0-9]+$` guard on `_RUNNER_RUN_PGID` before the kill, but the acquisition
path is controlled/trusted. Not a practical attack vector.

### pgrep output → kill
In both the watchdog KILL-escalation loop and the abort-trap orphan cleanup, lines from
`pgrep -P <trusted_pid>` are passed directly to `kill -KILL`. No numeric validation.
`pgrep` on a real OS only outputs numeric PIDs, and `kill` with a non-numeric argument
fails silently via `|| true`. Low risk, but a numeric whitelist check would be belt-and-suspenders.

### Sentinel file TOCTOU (_runner_signal_trap)
`_RUNNER_ABORT_REASON="$(_zbuild_abort_reason)"` reads `$ZBUILD_STATE_DIR/.abort.signal`
after the watchdog writes to it. The sentinel is operator-controlled (ZBUILD_STATE_DIR is
documented as a trusted engine path). An adversary with write access to that directory
could inject an abort word, but consequences are limited to metadata (run status) — no
command execution flows from the abort word. The `_at_abort_word` is only used in string
comparisons, not eval.

### No credentials/secrets exposed: confirmed.

## Findings summary
1. No numeric guard on pgrep output before kill (watchdog + abort trap) — low
2. template_max_run_s reads _TPL_SOURCE_FILE without path-confinement assertion — low
   (pre-existing pattern; new function follows it)
3. _RUNNER_ABORT_REASON now reads from sentinel file (TOCTOU) — low
4. No upper bound on accepted max_run_s values — low (by design; operator authority)

Score: 8 — well-validated main input paths; minor defense-in-depth gaps in process management code.
