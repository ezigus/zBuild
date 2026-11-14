## design — pass

- 10 SPEC(s): DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-1, DSADR-2, DSADR-3, DSBUD-1

- DSPRB-1 (covers RQPRO-1, RQWRK-1): zbuild_sed_inplace edits a file when ZBUILD_PLATFORM is set to a value that maps to the wrong sed form for the host
- DSPRB-2 (covers RQPRO-2, RQWRK-1): _zb_target_mode_v returns a valid octal mode when ZBUILD_PLATFORM is set to a value that maps to the wrong stat form for the host
- DSPRB-3 (covers RQPRO-3): The stat probe variable encodes the GNU form when the host's stat supports stat -c
- DSPRB-4 (covers RQSTT-1): Each call to _zb_target_mode_v on an existing file runs exactly one stat command
- DSPRB-5 (covers RQPRO-1): The sed probe module variable is set immediately after scripts/lib/compat.sh loads, before any call to zbuild_sed_inplace
- DSDEL-1 (covers RQDEL-1): zbuild_stat_size is not defined after scripts/lib/compat.sh is sourced
- DSADR-1 (covers RQADM-1): ADR-009 states that host tool-form decisions (which sed -i or stat form to use) come from a probe of the tool itself, run once when the library loads, and never from a platform name
- DSADR-2 (covers RQADM-2): ADR-009's new probe clause has an Enforced by subsection naming the test files that enforce it
- DSADR-3 (covers RQADM-3): zbuild_sed_inplace keeps its existing name after this change, so ADR-020's reference to it requires no amendment
- DSBUD-1 (covers RQBUD-1): The fork-budget-test.sh still passes after the probe change; the stat probe runs once at library load, adding no per-atomic_write process cost
- answered: design finding 1: done — Added DSPRB-5[code] to cover the "probe runs once when the file loads" aspect of RQPRO-1 that DSPRB-1 did not reach. DSPRB-5 checks that the sed probe module variable is non-empty immediately after sourcing `scripts/lib/compat.sh`, before any call to `zbuild_sed_inplace`. A non-empty probe variable at load time proves the probe ran at source time rather than per-call. RQPRO-1 has two independently testable behaviors (not from a platform name; runs once at load), so it correctly gets two SPECs: DSPRB-1 covers the "wrong platform still works" behavior, DSPRB-5 covers the "set at load time" behavior.
