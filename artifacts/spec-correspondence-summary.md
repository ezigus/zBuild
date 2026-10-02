## spec-correspondence — partial

- judged 15 SPEC(s): 13 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: the assertion checks result_contract, role:pr, and absence of cleanup: but never checks config.valid_verdicts contents, the three provides.events values, or primary:true on pr_url.
- SPEC-16 partial: the runtime checks target `$_art5` whose origin is merge delegation (not pr-open), so data.pr_url and data.draft assertions on that artifact may not reflect the pr-open path; the golden-file portion checks verdict, disposition, and pr_url but omits result_contract:2 and data.draft=false, leaving those two fields unestablished.

