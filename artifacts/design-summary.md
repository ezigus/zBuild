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
- answered: acceptance-gate finding 1: not mine — the finding reports that no test file contains assertions tagged with the design's SPEC ids (DSPRB-1 through DSDEL-1, DSADR-3, DSBUD-1). Writing test assertions and tagging them with SPEC ids is the test-author's responsibility, not the design's. My design correctly defines every SPEC with its id, Given/When/Then contract, and `covers:` mapping. The test-author stage is the output that must carry those tags into test files.
- answered: acceptance-gate finding 2: not mine — the reachability check failing for `scripts/lib/compat.sh` and `scripts/lib/helpers.sh` is a downstream consequence of the same missing test files: without any tagged test assertions, the pipeline has no test to fail when it reverts those files. My `WIRING: none` declaration is correct on its own terms: the probe variables are set and consumed entirely within the library files being modified; no external file calls the new probe behavior directly; external callers reach `zbuild_sed_inplace` and `_zb_target_mode_v` through unchanged function names. `WIRING: none` requires no change.
