# Security lens checkpoint — issue #1799

## Files read
- diff.patch: full diff; 4 files changed
- plugins/tool/pr-open/plugin.sh lines 120-199: _pr_open_run_inner new state-read logic

## Key findings so far

### 1. printf with data from state file / gate_aggregator_result (advisory-section.sh)
`_pr_open_render_gate_section` extracts `failed_gates` and `reason` from the gate_aggregator_result JSON via jq, then:
```bash
printf 'Failing gates: %s.' "${failed_gates:-none}"
[[ -n "$reason" ]] && printf ' %s' "$reason"
```
Format string is a fixed literal with `%s`; variable is an argument, not part of the format. No format-string injection possible.

### 2. jq interpolation of cycle_id into PR body (advisory-section.sh)
`_pr_open_render_convergence_section` uses:
```
jq -r '.[] | "> ⚠️ **\(.cycle_id) not converged** ..." <<< "$convergence_json"
```
cycle_id comes from pipeline-state.json (engine-written, trusted per repo facts). The result is PR body markdown text only — no code execution. Low theoretical risk: a compromised state file could inject markdown into the PR body.

### 3. _gate_aggregator_path from ZBUILD_STAGE_INPUTS
Engine-resolved trusted input per repo rules. Checked with `[[ -f "$gate_path" ]]` before use. No path traversal concern.

### 4. _state_status string comparison
`[[ "$_state_status" == "failed" ]]` — safe. No injection.

### 5. _max_iter_count regex validation
`[[ "${_max_iter_count:-0}" =~ ^[0-9]+$ ]]` — safe guard before arithmetic comparison.

### 6. No SIGPIPE violations
All `grep -q` calls in new test code read from named files, not pipes.

### 7. `_convergence_json` via here-string
`<<< "$convergence_json"` — here-string, no shell re-evaluation of content.

## Conclusions
- No injection of executable code found.
- No credential or secret exposure.
- No path traversal.
- The _gate_aggregator_path is validated with -f before use.
- Minor theoretical markdown-injection risk from cycle_id and reason fields, but these are trusted engine-internal data.

## If I had to stop here
Score: 8. One low finding: gate_aggregator reason/failed fields reflected verbatim into PR body (markdown injection from compromised artifact, low severity, introduced=true). One low finding: cycle_id from state file reflected verbatim into PR body (same).
