# Security lens notes — issue #1753

## Files read
- core/pipeline/strategies/map.sh (full)
- core/pipeline/runner.sh (lines 3700–3780)
- tests/unit/engine-combines-map-test.sh (full)
- tests/unit/runner-map-parallel-stage-envelope-test.sh (full)
- scripts/lib/helpers.sh (lines 1–60)
- plugins/agent/pr-delivery/plugin.sh (grep — ZBUILD_RUN_FLAGGED usage)
- plugins/tool/merge/plugin.sh (grep — ZBUILD_RUN_FLAGGED usage)
- plugins/tool/pr-open/plugin.sh (grep — ZBUILD_RUN_FLAGGED usage)

## Security check areas

### Injection risks

**map.sh line 157 change**: `[[ "$outcome" == fail ]]` → `[[ "$outcome" != pass ]]`
- `outcome` is jq-extracted from a plugin result file: `jq -r '.outcome // "missing"' "$res"`
- Used only in a `[[ ]]` comparison — safe, no injection risk
- The change is actually MORE fail-closed: any unknown outcome value triggers flagging

**runner.sh line 3740 — new error() call with _ZB_MAP_UNFINISHED**:
- `_ZB_MAP_UNFINISHED` = "K of N noun did not finish: <elem> (outcome), ..."
- `outcome` is jq-extracted, sanitized only of CR/LF (`gsub("[\r\n]+"; " ")`)
- `error()` uses `echo -e "$*"` — INTERPRETS backslash sequences
- A plugin that writes an outcome like `\033[2J` (terminal clear) or other ANSI escapes
  would have those interpreted when printed to stderr
- LIMITED to stderr (no pipeline logic impact); log injection / terminal manipulation only
- The `warn()` call at runner.sh:3712 was already there pre-change with same content,
  so this is not a completely new exposure — but the `error()` call at 3740 is new

**eb_emit_event with reason field (pre-existing, unchanged)**:
- `reason` is sanitized of CR/LF only; spaces are not sanitized
- `"reason=$reason"` form means spaces in reason would break event field parsing
- This is pre-existing behavior; not introduced by this change

### Credential/secret exposure
- No credentials or secrets involved in any changed line
- ZBUILD_RUN_FLAGGED is a boolean flag (yes/no), not sensitive data
- No new file paths that could contain credentials

### Path traversal
- No new file path construction introduced
- Existing path construction in _map_write_summary line 181:
  `"$art/${stage//[^A-Za-z0-9_.-]/_}-summary.md"` already sanitizes stage name (pre-existing)

### ZBUILD_RUN_FLAGGED trust boundary
- Set by `export ZBUILD_RUN_FLAGGED="$flagged"` in _map_write_summary — always overwrites
- `flagged` is a local bash variable initialized to "no" and only set to "yes" by [[ ]] comparison
- Cannot be externally injected by plugins (plugins write result files, not env vars)
- ZBUILD_* vars are documented as engine-set trusted inputs (CLAUDE.md)
- If set externally to "yes" before run: runner stops after map group — denial-of-service
  but not a bypass (fails closed). Pre-existing env cannot bypass it because
  _map_write_summary always overwrites it after the map runs.

### Early-return paths and stale ZBUILD_RUN_FLAGGED
- _strategy_run_map can return 0 (empty dimension) without calling _map_write_summary
  (lines 239-243). ZBUILD_RUN_FLAGGED would then retain the previous group's value.
- BUT: if the previous group set ZBUILD_RUN_FLAGGED=yes and returned 0 (continue mode),
  the runner would have already returned at line 3731. No second map group is reached.
- If no previous group ran: ZBUILD_RUN_FLAGGED is unset → [[ "" == yes ]] is false → safe
- Conclusion: no exploitable stale value issue

### eval in new test code — FINDING
File: tests/unit/runner-map-parallel-stage-envelope-test.sh, line 148
```
eval "$_spec4_rc_onward"
```
- `_spec4_rc_onward` is awk-extracted code from `$RUNNER_SH` (runner.sh)
- Runs in a subshell `( _spec4_runtime ) 2>/dev/null`
- No sanitization of extracted code fragment before eval
- If runner.sh is tampered, arbitrary code executes during the test suite
- This is a new pattern introduced by this change
- Subshell isolation limits parent shell variable write-back but NOT:
  - Filesystem writes (e.g., overwrite sensitive files via extracted code)
  - Arbitrary command execution within the subshell
- Attack path: modify runner.sh map: arm → inject code → CI test suite executes it via eval
- Severity: medium (requires runner.sh modification; test-only; subshell-contained)

## Score
8 — logic changes are sound and fail-closed; no credential/path issues; eval
in tests introduces a code injection path through the test suite in CI.
