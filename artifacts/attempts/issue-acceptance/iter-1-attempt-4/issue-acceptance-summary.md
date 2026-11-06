## issue-acceptance — fail

- judged the change against the issue: 3 requirement(s) not met or not sure

- 2 requirement(s) not met — each is a finding, sent to the stages that can fix it
- NOT SURE: ORDE-1: "Do not run this in parallel with another issue that edits the dispatch loop" is an operational/scheduling constraint. Nothing in the diff or repository enforces it mechanically; it cannot be verified by reading the code. What would settle it: CI or issue-tracking evidence that issue #1714 was not in flight concurrently with #1805. — "Do not run this in parallel with another issue that edits the dispatch loop (#1714 touches the allow-list builder in runner.sh)." — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
