# Claude SDK Blocking Call Inventory

Generated: 2026-04-30

Context: Audit performed as part of Fix 5 (non-blocking SDK transport) to resolve WIP branch
loss on 3-hour GitHub Actions pipeline timeouts. Bash `wait $!` is interruptible by USR1/INT/TERM
traps; blocking foreground claude calls are not.

Conversion threshold: calls with timeout >= 300s (5+ minutes) in the critical pipeline path.

## Converted (non-blocking `& wait $!` pattern)

| File | Line | Timeout | Reason converted |
|------|------|---------|-----------------|
| `scripts/lib/pipeline-stages-intake.sh` | ~479 | 3600s (configurable via `plan.claude_timeout`) | Plan stage — longest blocking call in the pipeline; 3-hour GHA runs were blocked here when watchdog fired |
| `scripts/lib/pipeline-stages-intake.sh` | ~1015 | unbounded (no explicit timeout; claude default) | Design stage — no timeout guard; can block signal delivery indefinitely |

## Not converted (retained blocking)

| File | Line | Timeout | Reason retained |
|------|------|---------|----------------|
| `scripts/lib/pipeline-stages-intake.sh` | ~690 | none (short `|| true`) | Plan validation — short, diagnostic call; uses `-p` flag (non-interactive); output already captured via `$(...)` subshell which is signal-safe |
| `scripts/lib/pipeline-stages-intake.sh` | ~758 | none (`|| true`) | Plan regen — only executes during validation retry loop; result written directly to file; signal safety is sufficient given outer `|| true` |
| `scripts/lib/pipeline-stages-build.sh` | ~67 | 120s | Below 300s threshold; acceptable blocking duration |
| `scripts/lib/pipeline-stages-build.sh` | ~627 | none | Short scoring call (`-p` single-turn); result used in awk; fire-and-forget pattern already present |
| `scripts/lib/pipeline-intelligence.sh` | ~164 | 30s | Well below threshold; diagnostic path |
| `scripts/sw-decompose.sh` | ~83 | none | `--max-turns 1` enforces single turn; short by design |
| `scripts/sw-discovery.sh` | ~208 | configurable (default low) | Not in pipeline critical path; uses own timeout cmd wrapper |
| `scripts/sw-intelligence.sh` | ~387 | 60s | Not in pipeline critical path; intelligence caching layer |
| `scripts/sw-quality.sh` | ~191 | 60s | Not in pipeline critical path; quality scoring utility |
| `scripts/sw-prep.sh` | ~728, ~1441 | none | Prep/analysis utility; not in the GHA pipeline hot path |
| `scripts/sw-logs.sh` | ~68 | none | Log analysis utility; not in pipeline critical path |

## Notes

- The `& wait $!` pattern preserves stdout/stderr redirection to existing files unchanged.
- Exit code semantics are identical: `wait $pid` returns the process exit code.
- For the plan stage the existing `_plan_exit=$?` variable captures the exit correctly.
- For the design stage the existing `|| true` is preserved via `wait "$_claude_bg_pid" || true`.
- Temp files are not needed because output is redirected directly to the target artifact file
  in both conversions — no intermediate temp file and therefore no cleanup risk.
- The `_claude_bg_pid` local variable is used to hold the PID; it is function-scoped and
  does not leak to callers.
