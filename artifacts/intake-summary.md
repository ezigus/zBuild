## intake — pass

- 10 requirement(s): RQADM-1, RQADM-2, RQADM-3, RQPRO-1, RQPRO-2, RQWRK-1, RQBUD-1, RQPRO-3, RQSTT-1, RQDEL-1

- RQADM-1: Amend ADR-009 to state that host decisions (which sed -i or stat form to use) come from a probe of the tools themselves, made once when the library loads, never from a platform name
- RQADM-2: The amendment to ADR-009 names its enforcing tests inline
- RQADM-3: If zbuild_sed_inplace is renamed, amend ADR-020 to name that function as the deferred tracker's log-update helper
- RQPRO-1: zbuild_sed_inplace picks its sed -i form from a probe run once when the file loads, not from a platform name
- RQPRO-2: _zb_target_mode_v picks its stat form from a probe run once when the file loads, not from a platform name
- RQWRK-1: With ZBUILD_PLATFORM set to a wrong value (e.g. ios), both functions still work on the host
- RQBUD-1: No extra process per atomic_write; the ADR-065 process budget test (tests/e2e/fork-budget-test.sh) must still pass
- RQPRO-3: Use the GNU form first (stat -c before stat -f)
- RQSTT-1: The probe replaces _zb_target_mode_v's second stat call so each mode check runs one stat
- RQDEL-1: zbuild_stat_size is deleted
