## spec-correspondence — partial

- judged 14 SPEC(s): 10 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-7 partial: The assertion greps for "- pass" and "- error" as list items anywhere in the manifest, so it would pass even if those values appeared under a different key than valid_verdicts.
- SPEC-11 partial: The assertion greps for "timeout_s:" and "max_turns:" anywhere in the manifest, so it would pass even if those keys appeared under a section other than config.router.
- SPEC-12 partial: The stub function reads $ZBUILD_ROUTER_MAX_TURNS_OVERRIDE directly from the environment rather than receiving the value from plugin code, so the assertion passes trivially whenever the env var is exported — regardless of whether the plugin actually honors it over the manifest value.
- SPEC-13 partial: The assertion greps for "primary: true" anywhere in the manifest, so it would pass even if that field appeared on a different output entry rather than the findings output specifically.

