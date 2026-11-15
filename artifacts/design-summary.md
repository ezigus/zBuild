## design — pass

- 11 SPEC(s): DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-1, DSADR-2, DSADR-3, DSBUD-1, DSBUD-2

- DSPRB-1 (covers RQPRO-1, RQWRK-1): zbuild_sed_inplace edits a file when ZBUILD_PLATFORM is set to a value that maps to the wrong sed form for the host
- DSPRB-2 (covers RQPRO-2, RQWRK-1): _zb_target_mode_v returns a valid octal mode when ZBUILD_PLATFORM is set to a value that maps to the wrong stat form for the host
- DSPRB-3 (covers RQPRO-3): The stat probe variable encodes the GNU form when the host's stat supports stat -c
- DSPRB-4 (covers RQSTT-1): Each call to _zb_target_mode_v on an existing file runs exactly one stat command
- DSPRB-5 (covers RQPRO-1): The sed probe module variable is set immediately after scripts/lib/compat.sh loads, before any call to zbuild_sed_inplace
- DSDEL-1 (covers RQDEL-1): zbuild_stat_size is not defined after scripts/lib/compat.sh is sourced
- DSADR-1 (covers RQADM-1): ADR-009 states that host tool-form decisions (which sed -i or stat form to use) come from a probe of the tool itself, run once when the library loads, and never from a platform name
- DSADR-2 (covers RQADM-2): ADR-009's new probe clause has an Enforced by subsection naming the test files that enforce it
- DSADR-3 (covers RQADM-3): zbuild_sed_inplace keeps its existing name after this change, so ADR-020's reference to it requires no amendment
- DSBUD-1 (covers RQBUD-1): The stat probe adds no extra stat process per atomic_write call after the probe change
- DSBUD-2 (covers RQBUD-1): tests/e2e/fork-budget-test.sh passes after the probe change
- answered: test-author finding 1: done — DSBUD-1 had two independent claims fused into one SPEC body. Separated them: DSBUD-1[no-code] now covers only "stat probe adds no extra stat per atomic_write call" (the sorted-CALLS assertion), and new DSBUD-2[no-code] covers "tests/e2e/fork-budget-test.sh exits 0 after the probe change." Both carry `covers: RQBUD-1`. Each claim is now independently assertable.
