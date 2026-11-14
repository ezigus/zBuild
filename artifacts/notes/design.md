# Design Notes — Issue #1700: Probe-Based Tool Selection

## What was read

### Implementation files (base code)

- `scripts/lib/compat.sh`: Contains `zbuild_sed_inplace` (checks `$ZBUILD_PLATFORM == "macos"`,
  picks `sed -i ''` or `sed -i`) and `zbuild_stat_size` (same pattern, no callers).
- `scripts/lib/helpers.sh`: Contains `_zb_target_mode_v`, which picks `stat -f '%Lp'` vs
  `stat -c '%a'` by checking `$ZBUILD_PLATFORM`. Makes two stat calls on the fallback path.
  `_zb_target_mode_v` is called by `atomic_write()` (line 197) and `replace_keep_mode()` (line 251).
- `zbuild_stat_size` is defined but has zero callers across the entire codebase.

### ADR files

- ADR-009: No "Enforced by" section. Documents platform-aware modularity (manifest fields,
  roles, resolver, fanout/composite/sequential strategies). No clause about how host tool
  forms are selected (probe vs platform name).
- ADR-020 (deferred-tracker): Names `zbuild_sed_inplace` from `scripts/lib/compat.sh`
  for log updates (line 224). Since we are NOT renaming the function, ADR-020 stays correct.
- ADR-065: Fork budget tracked in tests/e2e/fork-budget-test.sh. The probe runs once at
  load time, not per call, so it adds no process cost per atomic_write.

### Callers

- `zbuild_sed_inplace`: called by `scripts/lib/gh-automation.sh` (line 42) and
  `scripts/deferred-backfill.sh` (line 149).
- `_zb_target_mode_v`: called only within `scripts/lib/helpers.sh` itself, by
  `atomic_write()` and `replace_keep_mode()`.
- `compat.sh` is sourced by: `scripts/lib/helpers.sh`, `core/event-bus/event-bus.sh`,
  `scripts/lib/artifact-render.sh`, `tests/run-all.sh`.

### Existing SPEC ids (DS-prefixed)

Highest by prefix: DSWORK-9, DSFSTG-9, DSEND-1, DSFRSH-1, DSLOOP-1.
New prefixes used here: DSPRB (probe), DSDEL (delete), DSADR (ADR doc), DSBUD (budget).

## Key decisions

1. **Probe, not rename:** `zbuild_sed_inplace` keeps its name. ADR-020 already names it.
   RQADM-3 is conditional on renaming; since we do not rename, no ADR-020 amendment needed.

2. **GNU form first for stat probe** (RQPRO-3): try `stat -c '%a'` on a known path at
   load time; if it succeeds and returns an octal string, use GNU form. Otherwise use BSD.

3. **One stat per call** (RQSTT-1): old code tried platform-primary then fallback = two stat
   calls on failure path. With probe, one call.

4. **Probe at load time** (RQBUD-1): probe subshell runs once when the library is sourced
   (not per atomic_write call). The per-call budget is unchanged or reduced.

5. **WIRING**: The probe variables are set and consumed within the same library files being
   modified. No external file needs to change to reach the new behavior — callers use the
   same function names. WIRING: none is correct here.

## Round 2 fix

Finding 1 required a SPEC covering the "probe runs once when file loads" aspect of RQPRO-1.
DSPRB-1 covered "not from a platform name" but not the timing/frequency aspect.
Added DSPRB-5[code]: verifies that the sed probe module variable is non-empty immediately
after sourcing compat.sh, before any call to zbuild_sed_inplace. This proves the probe ran
at load time, not per-call.

DSPRB-1 retains its covers: RQPRO-1, RQWRK-1 for the "wrong platform still works" aspect.
DSPRB-5 also covers RQPRO-1 for the "runs once at load" aspect — RQPRO-1 has two testable
behaviors so it legitimately gets two SPECs.

## Status

Design is complete. Notes are a hand-off.
