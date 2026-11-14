## Design: Probe-Based Tool Selection for sed and stat (Issue #1700)

**Goal:** Replace `ZBUILD_PLATFORM` conditionals in `zbuild_sed_inplace` and
`_zb_target_mode_v` with probes of the actual tools, run once when each library
file loads. Delete the unused `zbuild_stat_size`. Document the approach in ADR-009.

**Context:** `zbuild_sed_inplace` (`scripts/lib/compat.sh`) and `_zb_target_mode_v`
(`scripts/lib/helpers.sh`) each pick between GNU and BSD tool forms by reading
`$ZBUILD_PLATFORM`. That check is fragile: a wrong or absent value breaks the function
even when the host's tool supports the needed form. `zbuild_stat_size` applies the same
anti-pattern and has no callers. `_zb_target_mode_v` currently makes two stat calls on
the first-choice fallback path; the probe eliminates that overhead.

**Decision:**
- `scripts/lib/compat.sh`: add a load-time sed probe (try the tool directly — no platform
  name); store result in a module-level variable; rewrite `zbuild_sed_inplace` to use it.
  Delete `zbuild_stat_size`.
- `scripts/lib/helpers.sh`: add a load-time stat probe, trying GNU form (`stat -c '%a'`)
  first (RQPRO-3); store result in a module-level variable; rewrite `_zb_target_mode_v`
  to call stat exactly once per invocation using the probed form.
- `zbuild_sed_inplace` keeps its name. ADR-020 already names it correctly; no
  amendment is needed (RQADM-3 is conditional on renaming; we do not rename).
- Amend ADR-009 with a new clause: host tool-form decisions come from a probe of the tool
  itself, run once at library load time, never from a platform name. Add an "Enforced by"
  subsection naming the enforcing tests inline.

```steps
- Add load-time sed probe variable; rewrite zbuild_sed_inplace to use it; delete zbuild_stat_size | areas: scripts/lib/compat.sh
- Add load-time stat probe variable (try stat -c first); rewrite _zb_target_mode_v to one stat call per invocation using probe | areas: scripts/lib/helpers.sh
- Amend ADR-009 with probe-over-platform-name clause and Enforced by subsection naming the new tests | areas: docs/adr/ADR-009-platform-aware-modularity.md
```

```acceptance
DSPRB-1[code]: zbuild_sed_inplace edits a file when ZBUILD_PLATFORM is set to a value that maps to the wrong sed form for the host covers: RQPRO-1, RQWRK-1
  Given: ZBUILD_PLATFORM=macos is exported before scripts/lib/compat.sh is sourced
  When: zbuild_sed_inplace is called with a substitution expression and a path to a writable file
  Then: the file content is changed as directed by the expression
  And: exit code is 0

DSPRB-2[code]: _zb_target_mode_v returns a valid octal mode when ZBUILD_PLATFORM is set to a value that maps to the wrong stat form for the host covers: RQPRO-2, RQWRK-1
  Given: ZBUILD_PLATFORM=macos is exported before scripts/lib/helpers.sh is sourced
  When: _zb_target_mode_v is called with an existing file path
  Then: the nameref variable holds a string matching ^[0-7]{3,4}$

DSPRB-3[code]: The stat probe variable encodes the GNU form when the host's stat supports stat -c covers: RQPRO-3
  Given: scripts/lib/helpers.sh is sourced on a host where stat -c '%a' succeeds on a known path
  When: the stat probe module variable is inspected immediately after sourcing
  Then: the probe encodes the GNU -c form, not the BSD -f form

DSPRB-4[code]: Each call to _zb_target_mode_v on an existing file runs exactly one stat command covers: RQSTT-1
  Given: scripts/lib/helpers.sh is sourced with the stat probe already set by load-time code
  When: _zb_target_mode_v is called with a path to an existing file
  Then: exactly one stat process runs (no second fallback stat)

DSPRB-5[code]: The sed probe module variable is set immediately after scripts/lib/compat.sh loads, before any call to zbuild_sed_inplace covers: RQPRO-1
  Given: scripts/lib/compat.sh is sourced in a fresh shell
  When: the sed probe module variable is inspected before zbuild_sed_inplace is called
  Then: the variable is non-empty (the probe ran at load time, not per-call)

DSDEL-1[code]: zbuild_stat_size is not defined after scripts/lib/compat.sh is sourced covers: RQDEL-1
  When: scripts/lib/compat.sh is sourced in a fresh shell
  Then: declare -f zbuild_stat_size exits non-zero

DSADR-1[doc]: ADR-009 states that host tool-form decisions (which sed -i or stat form to use) come from a probe of the tool itself, run once when the library loads, and never from a platform name covers: RQADM-1

DSADR-2[doc]: ADR-009's new probe clause has an Enforced by subsection naming the test files that enforce it covers: RQADM-2

DSADR-3[done]: zbuild_sed_inplace keeps its existing name after this change, so ADR-020's reference to it requires no amendment covers: RQADM-3 evidence: scripts/lib/compat.sh | zbuild_sed_inplace()
  When: scripts/lib/compat.sh is sourced after the probe change
  Then: declare -f zbuild_sed_inplace exits 0 (the function is defined under its original name)

DSBUD-1[no-code]: The fork-budget-test.sh still passes after the probe change; the stat probe runs once at library load, adding no per-atomic_write process cost covers: RQBUD-1

WIRING: none
```

The probe variables are set and consumed within the library files being modified
(`compat.sh`, `helpers.sh`). External callers (`gh-automation.sh`, `deferred-backfill.sh`,
`atomic_write`, `replace_keep_mode`) reach the new behavior through the same function
names they already call; no external file needs to change to wire the probe in.
