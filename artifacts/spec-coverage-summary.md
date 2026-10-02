## spec-coverage — uncovered

- The issue's #2250 additional acceptance checkbox requires both the result *and the summary* to reflect the blocked state — "the `pr` stage's result and summary say no PR was opened and name `review_signal_missing`" — but SPEC-22 covers only the pr-result.json content; no SPEC covers what pr-delivery-summary.md must say when pr-open returns rc=0 with verdict=blocked.

- NOT COVERED: #2250 additional acceptance — with no review report, the stage summary (pr-delivery-summary.md) must say no PR was opened and name `review_signal_missing` (today it says "pass — delivered the change by delegating to the pr-open stage")
- NOT COVERED: SPEC-22 covers the v2 result JSON but no SPEC names or tests the summary file content for this path
