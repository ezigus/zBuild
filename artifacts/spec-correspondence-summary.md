## spec-correspondence — partial

- judged 9 SPEC(s): 2 correspond, 7 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion tests only the timed_out disposition, but the requirement states suppression must fire for any of three dispositions — timed_out, out_of_turns, or interrupted.
- SPEC-3 partial: The assertion tests only rc=124; the requirement covers any non-zero exit from route_to_model, with rc=124 named only as a parenthetical example.
- SPEC-4 partial: The assertion tests only rc=1; the requirement states the disposition must be classified correctly whenever the router call exits non-zero, covering the full non-zero range.
- SPEC-5 partial: The assertion tests a single failing lens; the requirement says "one or more" and specifies behaviour for the first failed lens in a multi-lens failure, which the single-lens case does not establish.
- SPEC-7 partial: The assertion verifies the old exhausted/escalate vocabulary is absent but does not verify the replacement vocabulary (timed_out/out_of_turns) is present, which the requirement also requires.
- SPEC-8 partial: The assertion verifies _budget_guidance appears at least once, but the requirement demands each stage has its own helper, which a single-occurrence count does not establish.
- SPEC-9 partial: The assertion checks that "#2187" appears anywhere in the file, but the requirement calls for an amendment back-pointer — a specific structural context the grep for any occurrence does not confirm.

