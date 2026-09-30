## spec-coverage — uncovered

- Two issue requirements have no SPEC coverage: the manifest inputs must declare only `id` and `required:` (no path, type, or from/producer field), and the fallback-gh SUCCESS path must carry the v1 top-level fields (branch, pr_url, draft) inside `.data` for behavioral equivalence on a passing run.

- NOT COVERED: Manifest inputs must declare only `id` and `required:` — no path, no type, no producer/from field (issue §"Name-matched inputs")
- NOT COVERED: no SPEC constrains the manifest inputs structure, only SPEC-10 covers plugin.sh code
- NOT COVERED: The fallback-gh SUCCESS exit path currently writes `{status, branch, pr_url, draft}` at the top level — for behavioral equivalence those fields must be preserved under `.data` in v2, but SPEC-16 specifies only the top-level v2 envelope (`result_contract`, `verdict`, `disposition`, `reason`) and SPEC-19 covers only the dry-run path's `.data.branch` and `.data.draft`
