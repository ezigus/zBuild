## issue-acceptance — fail

- judged the change against the issue: 1 requirement(s) not met or not sure

- NOT SURE: ORDE-1: This is a workflow/process constraint — "do not run this in parallel with #1714". Nothing in the diff enforces or records it. It cannot be verified from code, tests, or the diff alone. Settling it would require checking whether #1714 touched runner.sh's dispatch loop in the same merge window. — "Do not run this in parallel with another issue that edits the dispatch loop (#1714 touches the allow-list builder in runner.sh)." — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
