## spec-coverage — uncovered

- Two issue requirements have no covering SPEC — one is actively contradicted by a SPEC that keeps what the issue says must be deleted.

- NOT COVERED: "every path this plugin constructs in code is deleted" — SPEC-18 explicitly retains the hardcoded `deploy-result.json`/`pr-url.txt` fallback path literals in plugin.sh "not deleted"
- NOT COVERED: cleanup (#1829) — no SPEC addresses the `release` hook or recording that it's absent when there's nothing to free.
