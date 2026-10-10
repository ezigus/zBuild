## issue-acceptance — fail

- R-2, R-3, and R-4 are fully met (test suite passes 844/0, both templates cleaned, ADR-068 amended with correct §1/§8 text and updated Enforced-by), but R-1's "state the red step in the PR body" is not verifiable from the diff, and R-5 cannot be confirmed because the current pipeline run itself dispatched the impact stage (using the pre-change templates), so no post-merge run without impact is yet in evidence.

- NOT SURE: R-1: the diff cannot confirm the red step was stated in the PR body — that documentation requirement is not visible in any changed file — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: R-5: a dogfood run completing with no impact stage and no stage-resolution warning has not been observed — the current pipeline run dispatched impact (verdict: warn), which is consistent with running on the old templates, but provides no evidence of a clean post-merge run — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
