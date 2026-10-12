## spec-correspondence — partial

- judged 12 SPEC(s): 7 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: the assertion confirms `timed_out` appears somewhere in the dispatch path but does not verify the disposition content names the stage and the limit, as the requirement requires.
- SPEC-2 partial: the assertion covers the internal watchdog path (set -m, zbuild_pg_kill, _zbuild_pg_term_then_kill, ≥10 s grace) but does not test the external-SIGTERM path — "when the runner is externally killed, its signal handler must also kill any isolated hook process group" is explicitly deferred to the integration test and absent here.
- SPEC-3 partial: tier 1 (template beats env) is directly verified; tier 2 (env beats default) accepts `<unset>` as a passing value, which only shows the loader does not hardcode 5400 rather than positively confirming env is applied at dispatch; tier 3 only greps for the literal 5400 without a behavioral test that confirms it is the fallback when neither env nor template is set.
- SPEC-7 partial: absence of `ZBUILD_ORCH_TIMEOUT` from all three strategy files is verified, but the behavioral claim — that a dispatch running longer than 300 s but within `stage_timeout_s` completes without being killed — is not directly tested.
- SPEC-9 partial: the "cannot be found" case (unknown alias, non-zero return, no orch-sequential fallback) is fully covered, but the "whose config is unreadable" case is not tested.

