## spec-correspondence — mismatch

- judged 15 SPEC(s): 13 correspond, 1 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion checks result_contract:2, role:pr, and absence of cleanup:, but does not assert config.valid_verdicts contents, provides.events entries, or primary:true on pr_url.
- SPEC-16 MISMATCH: The live-run checks use $_art5, which is the artifact from SPEC-5's merge-delegation subshell (policy=auto, merge mock), not a pr-open delegation run; the requirement names the pr-open delegation path specifically, so the evidence is for the wrong code path.

