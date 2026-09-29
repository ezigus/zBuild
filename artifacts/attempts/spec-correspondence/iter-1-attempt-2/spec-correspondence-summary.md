## spec-correspondence — partial

- judged 17 SPEC(s): 15 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-3 partial: The assertion verifies the new rc=1/plan.json/out_of_turns behavior and that plan.scope_too_large still fires, but does not verify that the old assertions expecting rc=10 and no plan.json were removed from plan-integration-test.sh, which is an explicit part of the requirement.
- SPEC-7 partial: The assertion checks specific step content (id and description) to establish content preservation for steps[], but for scope_files[] it only asserts length > 0, which the requirement explicitly distinguishes from sufficient ("not merely non-empty").

