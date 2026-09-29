## spec-correspondence — partial

- judged 18 SPEC(s): 16 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-3 partial: The assertion establishes rc=1, disposition=out_of_turns, and plan.scope_too_large firing, but the requirement also requires removal of old rc=10/no-plan.json assertions from plan-integration-test.sh lines ~236-262, which the assertion does not check.
- SPEC-16 partial: The assertion verifies runner.sh has 35 legacy-rc occurrences (establishing the block's deletion), but the requirement also requires dispatch-rc-guard-test.sh's pin to be lowered from 36 to 35, which is not checked.

